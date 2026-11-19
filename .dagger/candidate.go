package main

import (
	"context"
	"fmt"
	"strings"

	"dagger/omarchy-bootc/internal/dagger"
)

// Ubuntu worker for the existing scripts. Podman's own layer cache is explicit;
// it is not supplied by Dagger's execution cache, and belongs to this engine.
func (m *OmarchyBootc) candidateWorker(bundle *dagger.File, head, executionID string) *dagger.Container {
	return dag.Container().From("mcr.microsoft.com/devcontainers/base:ubuntu-24.04").
		WithUser("root").
		WithExec([]string{"bash", "-ceu", `sed -i 's|http://archive.ubuntu.com/ubuntu|https://mirrors.edge.kernel.org/ubuntu|g; s|http://security.ubuntu.com/ubuntu|https://mirrors.edge.kernel.org/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources
apt-get -o Acquire::Retries=3 -o Acquire::https::Timeout=30 -o APT::Update::Error-Mode=any update
DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 -o Acquire::https::Timeout=30 install -y --no-install-recommends podman buildah skopeo jq git sudo python3 shellcheck time util-linux btrfs-progs`}).
		WithNewFile("/etc/containers/storage.conf", "[storage]\ndriver=\"overlay\"\ngraphroot=\"/var/lib/containers/storage\"\nrunroot=\"/run/containers/storage\"\n").
		WithNewFile("/etc/containers/containers.conf", "[engine]\ncgroup_manager=\"cgroupfs\"\nevents_logger=\"file\"\n").
		WithMountedCache("/var/lib/containers", dag.CacheVolume("omarchy-podman-linux-amd64-v1"), dagger.ContainerWithMountedCacheOpts{Sharing: "LOCKED"}).
		WithDirectory("/src", m.Source).
		WithFile("/input/source.bundle", bundle).
		WithEnvVariable("EXPECTED_SOURCE_HEAD", head).
		WithEnvVariable("PIPELINE_EXECUTION_ID", executionID).
		WithEnvVariable("BUILDAH_LAYERS", "true").
		WithEnvVariable("CANDIDATE_ARTIFACT_DIR", "/out/candidate").
		WithWorkdir("/src")
}

// Run the same inexpensive source contracts before any image build.
func (m *OmarchyBootc) SourceContracts(gitBundle *dagger.File, sourceHead string, executionID string) *dagger.Directory {
	return m.candidateWorker(gitBundle, sourceHead, executionID).
		WithEnvVariable("DAGGER_PHASE", "source").
		WithExec([]string{"bash", "scripts/ci/dagger-candidate.sh"}).Directory("/out")
}

// Probe real nested rootful Podman before migrating privileged stages.
// The returned evidence must pass CheckResult; export remains possible on failure.
func (m *OmarchyBootc) NestedProbe(
	gitBundle *dagger.File,
	sourceHead string,
	executionID string,
) *dagger.Directory {
	return m.candidateWorker(gitBundle, sourceHead, executionID).
		WithEnvVariable("DAGGER_PHASE", "probe").
		WithExec([]string{"bash", "scripts/ci/dagger-candidate.sh"}, dagger.ContainerWithExecOpts{InsecureRootCapabilities: true}).Directory("/out")
}

// Build/export all existing OCI stages with separate Dagger execution boundaries.
// executionID forces real cold/warm executions instead of replaying a cached result.
func (m *OmarchyBootc) CandidateBuild(
	gitBundle *dagger.File,
	sourceHead string,
	executionID string,
) *dagger.Directory {
	worker := m.candidateWorker(gitBundle, sourceHead, executionID)
	for _, phase := range []string{"source", "preflight", "packages", "foundation", "assembly", "integration", "build", "identity"} {
		worker = worker.WithEnvVariable("DAGGER_PHASE", phase).
			WithExec([]string{"bash", "scripts/ci/dagger-candidate.sh"}, dagger.ContainerWithExecOpts{InsecureRootCapabilities: true})
	}
	return worker.Directory("/out")
}

// Fail closed after exporting diagnostic artifacts, including failed executions.
// A successful export alone is never an accepted build or VM result.
func (m *OmarchyBootc) CheckResult(ctx context.Context, status *dagger.File) (string, error) {
	code, err := status.Contents(ctx)
	if err != nil {
		return "", fmt.Errorf("missing pipeline status: %w", err)
	}
	if strings.TrimSpace(code) != "0" {
		return "", fmt.Errorf("pipeline failed (exit %s); inspect exported evidence", strings.TrimSpace(code))
	}
	return "Pipeline execution passed; VM acceptance is a separate required gate", nil
}
