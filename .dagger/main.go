package main

import (
	"context"
	"fmt"
	"regexp"
	"strings"

	"dagger/omarchy-bootc/internal/dagger"
)

const (
	defaultLiveRootfsImage = "ghcr.io/ublue-os/bluefin-dx:stable"
	defaultImageTag        = "stable"
	defaultRepoImage       = "ghcr.io/joshyorko/omarchy-bootc"
	titanoboaImage         = "ghcr.io/ublue-os/devcontainer:titanoboa"
	titanoboaRef           = "840217d97bd0bc9a52466508c54d8dda5c5ba2fd"
)

var artifactNamePattern = regexp.MustCompile(`[^A-Za-z0-9._-]+`)
var immutableRefPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]*@sha256:[0-9a-f]{64}$`)
var trackingRefPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9][A-Za-z0-9._-]*$`)

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
		"git clone --depth 1 https://github.com/ublue-os/titanoboa.git /tmp/titanoboa",
		`git -C /tmp/titanoboa fetch --depth 1 origin "${TITANOBOA_REF}"`,
		`git -C /tmp/titanoboa checkout "${TITANOBOA_REF}"`,
		"cd /tmp/titanoboa",
		"if command -v sudo >/dev/null 2>&1; then run=(sudo env); else run=(env); fi",
		`"${run[@]}" PATH="$PATH" CI=true HOOK_post_rootfs=/tmp/iso-hooks/configure_iso_anaconda.sh HOOK_pre_initramfs=/src/iso_files/pre_initramfs_enable_repos.sh TITANOBOA_BUILDER_DISTRO=fedora just build "${LIVE_ROOTFS_IMAGE}" 1 none squashfs NONE "${INSTALL_IMAGE_REF}" 1`,
		`mv /tmp/titanoboa/output.iso "/out/${OUTPUT_NAME}.iso"`,
		"cd /out",
		`sha256sum "${OUTPUT_NAME}.iso" > "${OUTPUT_NAME}.iso-CHECKSUM"`,
	}, "\n")

	return dag.Container().
		From(titanoboaImage).
		WithMountedDirectory("/src", m.Source).
		WithWorkdir("/src").
		WithEnvVariable("INSTALL_IMAGE_REF", installImageRef).
		WithEnvVariable("TRACKING_IMAGE_REF", trackingImageRef).
		WithEnvVariable("LIVE_ROOTFS_IMAGE", liveRootfsImage).
		WithEnvVariable("OUTPUT_NAME", artifactName).
		WithEnvVariable("TITANOBOA_REF", titanoboaRef).
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
