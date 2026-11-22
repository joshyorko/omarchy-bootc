package main

import (
	"context"
	_ "embed"
	"fmt"
	"regexp"
	"strings"

	"dagger/omarchy-bootc/internal/dagger"
)

const (
	defaultLiveRootfsImage = "ghcr.io/ublue-os/bluefin-dx:stable"
	defaultImageTag        = "stable"
	defaultRepoImage       = "ghcr.io/joshyorko/omarchy-bootc"
	titanoboaImage         = "ghcr.io/ublue-os/devcontainer@sha256:69f158620fc2677a6da14e385494be0d028030221c413287ddfedb12a0b75bd0"
	titanoboaRef           = "840217d97bd0bc9a52466508c54d8dda5c5ba2fd"
	isoContainersConfig    = "[containers]\ncgroups=\"disabled\"\n"
)

var artifactNamePattern = regexp.MustCompile(`[^A-Za-z0-9._-]+`)
var immutableRefPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]*@sha256:[0-9a-f]{64}$`)
var trackingRefPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9][A-Za-z0-9._-]*$`)

//go:embed titanoboa-compat.py
var titanoboaCompatibility string

type OmarchyBootc struct {
	Source *dagger.Directory
}

func New(
	// +defaultPath="/"
	// +ignore=[".git", ".codex", "output", "*_build*"]
	source *dagger.Directory,
) *OmarchyBootc {
	return &OmarchyBootc{Source: source}
}

// Validate repo structure and shell/Just syntax inside Dagger.
func (m *OmarchyBootc) Validate(ctx context.Context) (string, error) {
	return dag.Container().
		From("debian:bookworm-slim").
		WithMountedDirectory("/src", m.Source).
		WithWorkdir("/src").
		WithExec([]string{"bash", "-lc", strings.Join([]string{
			"set -euo pipefail",
			"apt-get update",
			"DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl jq shellcheck shfmt tar",
			"curl -fsSL -o /tmp/just.tar.gz https://github.com/casey/just/releases/download/1.47.1/just-1.47.1-x86_64-unknown-linux-musl.tar.gz",
			"tar -xzf /tmp/just.tar.gz -C /usr/local/bin just",
			"rm -rf /var/lib/apt/lists/*",
			"just --unstable --fmt --check -f Justfile",
			"find . -iname '*.sh' -not -path './.git/*' -exec shellcheck '{}' ';'",
		}, "\n")}).
		Stdout(ctx)
}

// Render the installer hook scripts used by the ISO build.
func (m *OmarchyBootc) RenderIsoHooks(
	// Verified immutable OCI image reference (@sha256:...) installed by the ISO.
	installImageRef string,
	// Mutable tracking stream reference for future bootc upgrades.
	// +optional
	trackingImageRef string,
) (*dagger.Directory, error) {
	if !immutableRefPattern.MatchString(installImageRef) {
		return nil, fmt.Errorf("installImageRef must be an immutable digest reference: %q", installImageRef)
	}
	trackingImageRef = defaultString(trackingImageRef, defaultRepoImage+":"+defaultImageTag)
	if !trackingRefPattern.MatchString(trackingImageRef) || strings.Contains(trackingImageRef, "@sha256:") {
		return nil, fmt.Errorf("trackingImageRef must be a mutable channel tag reference: %q", trackingImageRef)
	}

	return dag.Container().
		From("debian:bookworm-slim").
		WithMountedDirectory("/src", m.Source).
		WithWorkdir("/src").
		WithEnvVariable("INSTALL_IMAGE_REF", installImageRef).
		WithEnvVariable("TRACKING_IMAGE_REF", trackingImageRef).
		WithExec([]string{"bash", "-lc", strings.Join([]string{
			"set -euo pipefail",
			"mkdir -p /out",
			`install_rep="$(printf '%s' "${INSTALL_IMAGE_REF}" | sed 's/[\\&|]/\\&/g')"`,
			`track_rep="$(printf '%s' "${TRACKING_IMAGE_REF}" | sed 's/[\\&|]/\\&/g')"`,
			`sed -e "s|@@INSTALL_IMAGE_REF@@|${install_rep}|g" -e "s|@@TRACKING_IMAGE_REF@@|${track_rep}|g" iso_files/configure_iso_anaconda.sh.in > /out/configure_iso_anaconda.sh`,
			"cp iso_files/pre_initramfs_enable_repos.sh /out/pre_initramfs_enable_repos.sh",
			"chmod +x /out/configure_iso_anaconda.sh /out/pre_initramfs_enable_repos.sh",
		}, "\n")}).
		Directory("/out"), nil
}

// Verify the pinned outer toolchain; keep Titanoboa's nesting guard.
func isoBuilderContainer() *dagger.Container {
	return dag.Container().From(titanoboaImage).
		WithUser("root").
		// Dagger does not delegate nested cgroup controllers to Podman.
		WithNewFile("/etc/containers/containers.conf.d/90-omarchy-dagger.conf", isoContainersConfig).
		WithExec([]string{"bash", "-ceu", `packages=(python3 dosfstools grub2 grub2-efi grub2-tools grub2-tools-extra shim xorriso)
case "$(uname -m)" in
    x86_64) packages+=(grub2-efi-x64 grub2-efi-x64-cdboot grub2-efi-x64-modules) ;;
    aarch64) packages+=(grub2-efi-aa64-modules) ;;
    *) echo 'Unsupported ISO builder architecture' >&2; exit 1 ;;
esac
for package in "${packages[@]}"; do
    printf '%s -> ' "$package"
    rpm -q --whatprovides "$package"
done`}, dagger.ContainerWithExecOpts{InsecureRootCapabilities: true}).
		WithEnvVariable("TITANOBOA_REF", titanoboaRef).
		WithNewFile("/usr/libexec/omarchy-titanoboa-compat.py", titanoboaCompatibility).
		WithExec([]string{"bash", "-lc", strings.Join([]string{
			"set -euo pipefail",
			// Upstream's final recipe writes /app/output.iso, even without a nested builder.
			"git clone --depth 1 https://github.com/ublue-os/titanoboa.git /app",
			`git -C /app fetch --depth 1 origin "${TITANOBOA_REF}"`,
			`git -C /app checkout "${TITANOBOA_REF}"`,
			"python3 /usr/libexec/omarchy-titanoboa-compat.py /app/Justfile",
			"cd /app",
			"just --summary",
		}, "\n")}).WithWorkdir("/app")
}

// Exercise the real final ISO recipe before downloading a full live rootfs.
func (m *OmarchyBootc) IsoBuilderPreflight(ctx context.Context) (string, error) {
	return isoBuilderContainer().
		WithExec([]string{"bash", "-lc", strings.Join([]string{
			"set -euo pipefail",
			"just --version",
			"if command -v sudo >/dev/null 2>&1; then run=(sudo -n env); else run=(env); fi",
			`"${run[@]}" podman info --format=json`,
			`"${run[@]}" podman run --rm -it --privileged --security-opt label=disable docker.io/library/alpine:3.21 sh -ceu 'test "$(id -u)" = 0; mount -t tmpfs tmpfs /mnt; umount /mnt; echo ISO_BUILDER_NESTED_OK'`,
			// No kernel, payload or installer: this only verifies boot-media tooling.
			"mkdir -p work/iso-root/boot/grub",
			`printf 'set timeout=0\n' > work/iso-root/boot/grub/grub.cfg`,
			`git show "${TITANOBOA_REF}:Justfile" > Justfile.name-only; sed -i '1i set lists' Justfile.name-only`,
			`baseline=$(bash -ceu "$(just --justfile Justfile.name-only --evaluate iso_dependencies); iso_dependencies"); echo "NAME_ONLY_MISSING=$baseline"; (( baseline > 0 ))`,
			`dependencies=$(just --evaluate iso_dependencies); missing=$(bash -ceu "$dependencies; iso_dependencies"); echo "PROVIDER_MISSING=$missing"; [[ $missing == 0 ]]`,
			// Exercise the real installed RPM database with an absent capability;
			// the actual final recipe must still stop at its nesting guard.
			`missing_dependencies=$(printf '%s' "$dependencies" | sed 's/local RPMS=(/local RPMS=( omarchy-preflight-absent-capability /')`,
			`missing=$(bash -ceu "$missing_dependencies; iso_dependencies"); echo "NEGATIVE_MISSING=$missing"; [[ $missing == 1 ]]`,
			`if CI=true just "iso_dependencies=$missing_dependencies" iso > /tmp/iso-missing.log 2>&1; then echo 'Missing ISO capability was accepted' >&2; exit 1; fi`,
			`grep -F 'Cannot run in nested containers' /tmp/iso-missing.log`,
			"CI=true just iso",
			"test -s /app/output.iso",
			// Exercise the actual build wrapper without repeating its heavy dependencies.
			"just --no-deps build",
			"sha256sum /app/output.iso",
			"echo 'ISO_FINAL_RECIPE_PREFLIGHT_OK: tooling fixture only, not installer or guest qualification'",
		}, "\n")}, dagger.ContainerWithExecOpts{InsecureRootCapabilities: true}).Stdout(ctx)
}

// Build the installer ISO with Titanoboa and return an exportable output directory.
func (m *OmarchyBootc) BuildIso(
	// OCI image tag used for artifact naming and default tracking stream.
	// +optional
	imageTag string,
	// Verified immutable OCI image reference (@sha256:...) installed by the ISO.
	installImageRef string,
	// Mutable tracking stream reference for future bootc upgrades.
	// +optional
	trackingImageRef string,
	// Fedora-based live rootfs image used for the installer environment.
	// +optional
	liveRootfsImage string,
) (*dagger.Directory, error) {
	imageTag = defaultString(imageTag, defaultImageTag)
	liveRootfsImage = defaultString(liveRootfsImage, defaultLiveRootfsImage)
	if !immutableRefPattern.MatchString(installImageRef) {
		return nil, fmt.Errorf("installImageRef must be an immutable digest reference: %q", installImageRef)
	}
	trackingImageRef = defaultString(trackingImageRef, defaultRepoImage+":"+imageTag)
	if !trackingRefPattern.MatchString(trackingImageRef) || strings.Contains(trackingImageRef, "@sha256:") {
		return nil, fmt.Errorf("trackingImageRef must be a mutable channel tag reference: %q", trackingImageRef)
	}

	artifactName := sanitizeArtifactName(fmt.Sprintf("omarchy-bootc-%s-installer-x86_64", imageTag))
	script := strings.Join([]string{
		"set -euo pipefail",
		"command -v git",
		"command -v just",
		"mkdir -p /tmp/iso-hooks /out",
		`install_rep="$(printf '%s' "${INSTALL_IMAGE_REF}" | sed 's/[\\&|]/\\&/g')"`,
		`track_rep="$(printf '%s' "${TRACKING_IMAGE_REF}" | sed 's/[\\&|]/\\&/g')"`,
		`sed -e "s|@@INSTALL_IMAGE_REF@@|${install_rep}|g" -e "s|@@TRACKING_IMAGE_REF@@|${track_rep}|g" /src/iso_files/configure_iso_anaconda.sh.in > /tmp/iso-hooks/configure_iso_anaconda.sh`,
		"chmod +x /tmp/iso-hooks/configure_iso_anaconda.sh",
		"cd /app",
		"if command -v sudo >/dev/null 2>&1; then run=(sudo env); else run=(env); fi",
		`"${run[@]}" PATH="$PATH" CI=true HOOK_post_rootfs=/tmp/iso-hooks/configure_iso_anaconda.sh HOOK_pre_initramfs=/src/iso_files/pre_initramfs_enable_repos.sh TITANOBOA_BUILDER_DISTRO=fedora just build "${LIVE_ROOTFS_IMAGE}" 1 none squashfs NONE "${INSTALL_IMAGE_REF}" 1`,
		`mv /app/output.iso "/out/${OUTPUT_NAME}.iso"`,
		"cd /out",
		`sha256sum "${OUTPUT_NAME}.iso" > "${OUTPUT_NAME}.iso-CHECKSUM"`,
	}, "\n")

	return isoBuilderContainer().
		WithMountedDirectory("/src", m.Source).
		WithEnvVariable("INSTALL_IMAGE_REF", installImageRef).
		WithEnvVariable("TRACKING_IMAGE_REF", trackingImageRef).
		WithEnvVariable("LIVE_ROOTFS_IMAGE", liveRootfsImage).
		WithEnvVariable("OUTPUT_NAME", artifactName).
		WithExec([]string{"bash", "-lc", script}, dagger.ContainerWithExecOpts{
			InsecureRootCapabilities: true,
		}).
		Directory("/out"), nil
}

func defaultString(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func sanitizeArtifactName(value string) string {
	value = artifactNamePattern.ReplaceAllString(value, "-")
	return strings.Trim(value, "-")
}
