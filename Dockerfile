# Global ARG declarations - must be at the top, before ANY FROM statement
# Keep in sync with Tailscale's go.mod; GOTOOLCHAIN=auto below covers patch/minor drift.
ARG GO_VERSION=1.26
ARG TAILSCALE_VERSION # Set via --build-arg or determined in builder stage
ARG GOOS=linux
ARG GOARCH # Set via --build-arg
ARG GOARM # Set via --build-arg (optional)
ARG ACAP_ARCH_TAG # Set via --build-arg (e.g., armv7hf, aarch64)
ARG SDK_VERSION # Set via --build-arg
ARG UBUNTU_VERSION=22.04
ARG REPO=axisecp
ARG SDK=acap-native-sdk
ARG APP_USERNAME # Set via --build-arg (optional)
ARG TAILSCALE_UP_OPTS # Set via --build-arg, default provided by build.sh
ARG UPX_COMPRESS=0 # Set to 1 to pack the binary with UPX

# Tailscale features to keep in the build. Everything not listed here (and not
# pulled in as a dependency of something listed here) is omitted via a
# ts_omit_* build tag. See the "Feature selection" section in the README for
# the rationale behind each entry.
ARG TS_FEATURES="cli,ipnbus,netstack,osrouter,iptables,dns,useroutes,useexitnode,advertiseroutes,advertiseexitnode,ssh,health,portmapper,listenrawdisco,cachenetmap,gro,bakedroots,tailnetlock,doctor,cliconndiag,unixsocketidentity,linkspeed,tundevstats"

# === Stage 1: Build the combined Tailscale binary ===
FROM golang:${GO_VERSION} AS builder

# Official golang images pin GOTOOLCHAIN=local, which rejects go.mod versions newer
# than the image. Allow the toolchain to fetch what Tailscale requires.
ENV GOTOOLCHAIN=auto

# Expose the build settings to this stage
ARG GOOS
ARG GOARCH
ARG GOARM
ARG TAILSCALE_VERSION=latest
ARG TS_FEATURES
ARG UPX_COMPRESS

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        file \
        curl \
        jq; \
    rm -rf /var/lib/apt/lists/*;

WORKDIR /src

# A full clone is required: cmd/mkversion derives the version stamp with
# "git rev-list --count HEAD ^<commit that last touched VERSION.txt>", which
# needs real history. Shallow fetches make that count wrong or fail outright.
RUN git clone https://github.com/tailscale/tailscale.git

WORKDIR /src/tailscale

# Determine the target version: Use provided TAILSCALE_VERSION arg,
# otherwise fetch the latest *release* tag from GitHub API.
RUN set -eux; \
    TARGET_TAG=""; \
    if [ -n "${TAILSCALE_VERSION}" ] && [ "${TAILSCALE_VERSION}" != "latest" ]; then \
      TARGET_TAG="${TAILSCALE_VERSION}"; \
      echo ">>> Using specified Tailscale tag: $TARGET_TAG"; \
    else \
      echo ">>> Fetching latest stable release tag from GitHub API..."; \
      API_URL="https://api.github.com/repos/tailscale/tailscale/releases/latest"; \
      LATEST_RELEASE_TAG=$(curl -sfSL "${API_URL}" | jq -r .tag_name || true); \
      if [ -n "$LATEST_RELEASE_TAG" ] && [ "$(echo $LATEST_RELEASE_TAG | cut -c1)" = "v" ]; then \
        TARGET_TAG="$LATEST_RELEASE_TAG"; \
        echo ">>> Using latest stable release tag from GitHub API: $TARGET_TAG"; \
      else \
        echo "!!! GitHub API returned tag '$LATEST_RELEASE_TAG'. Falling back to git tag logic..."; \
        TARGET_TAG=$(git tag -l 'v*' --sort=-v:refname | grep -v -E 'rc|beta|alpha' | head -n 1); \
        if [ -z "$TARGET_TAG" ]; then \
            echo "!!! FATAL: Could not determine any latest tag via git fallback."; exit 1; \
        fi; \
        echo ">>> Using latest tag found via git fallback: $TARGET_TAG"; \
      fi; \
    fi; \
    echo ">>> Checking out $TARGET_TAG..."; \
    git -c advice.detachedHead=false checkout "$TARGET_TAG"

# Resolve TS_FEATURES into a Go build tag list.
#
# cmd/featuretags only validates names passed to --remove, not --add: an
# unknown name in --add is silently accepted and the feature it was meant to
# keep gets omitted anyway. Validate against --list first so a typo fails the
# build instead of quietly shipping a crippled binary.
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg \
    set -eu; \
    mkdir -p /out; \
    go run ./cmd/featuretags --list | sed -n 's/^[[:space:]]*\([^:]*\):.*/\1/p' > /tmp/known_features; \
    MISSING=""; \
    for f in $(echo "${TS_FEATURES}" | tr ',' ' '); do \
        grep -qx -- "$f" /tmp/known_features || MISSING="${MISSING} $f"; \
    done; \
    if [ -n "${MISSING}" ]; then \
        echo "!!! FATAL: unknown Tailscale feature(s):${MISSING}"; \
        echo "!!! Known features:"; sed 's/^/!!!   /' /tmp/known_features; \
        exit 1; \
    fi; \
    go run ./cmd/featuretags --min --add="${TS_FEATURES}" > /out/build_tags.txt; \
    echo "--- Keeping features: ${TS_FEATURES}"; \
    echo "--- Resolved build tags: $(cat /out/build_tags.txt)"

# Build a single binary containing both the daemon and the CLI.
#
# The "cli" feature emits the ts_include_cli tag, which links cmd/tailscale/cli
# into cmd/tailscaled. The binary then behaves as the CLI when argv[0] is
# "tailscale" or when TS_BE_CLI is set, and as the daemon otherwise.
#
#   -s -w        strip symbol table & DWARF info
#   -buildid=    omit the build ID
#   -trimpath    remove GOPATH and module root prefixes from file paths
#   -buildvcs=false  do not embed VCS metadata (we stamp the version explicitly)
#   -X ...Stamp  burn in the version, as tailscale's own build_dist.sh does;
#                without these the node reports a devel version to the control plane
#   CGO_ENABLED=0  fully static pure-Go binary, no libc dependency
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg \
    set -eu; \
    eval "$(./build_dist.sh shellvars)"; \
    echo "--- Version stamps: short=${VERSION_SHORT} long=${VERSION_LONG}"; \
    GOOS=${GOOS} GOARCH=${GOARCH} GOARM=${GOARM:-} CGO_ENABLED=0 go build \
        -v \
        -tags "$(cat /out/build_tags.txt)" \
        -trimpath \
        -buildvcs=false \
        -ldflags "-s -w -buildid= -X tailscale.com/version.longStamp=${VERSION_LONG} -X tailscale.com/version.shortStamp=${VERSION_SHORT}" \
        -o /out/tailscaled \
        ./cmd/tailscaled; \
    printf '%s\n' "${VERSION_SHORT}" > /out/tailscale_version_short.txt

# Record the release tag separately from the version stamp: the tag is what the
# artifact is named after, and it is needed even when packaging is done in a
# stage that has no git checkout.
RUN set -eu; \
    TS_VER=$(git describe --tags --abbrev=0); \
    printf '%s\n' "${TS_VER}" > /out/tailscale_version.txt; \
    echo "--- Captured Tailscale release tag: ${TS_VER}"

# Optionally pack the binary with UPX. This roughly quarters the on-flash size
# at the cost of the whole binary being resident in RAM after self-extraction,
# plus decompression on every invocation (including CLI calls).
RUN set -eu; \
    if [ "${UPX_COMPRESS}" = "1" ]; then \
        apt-get update && apt-get install -y --no-install-recommends upx-ucl && rm -rf /var/lib/apt/lists/*; \
        echo "--- Size before UPX:"; du -h /out/tailscaled; \
        upx --lzma --best /out/tailscaled; \
        echo "--- Size after UPX:"; du -h /out/tailscaled; \
    else \
        echo "--- UPX compression disabled"; \
    fi

RUN file /out/tailscaled && du -h /out/tailscaled

# === Stage 2: Build ACAP Package ===
# Force this stage to run on linux/amd64, as the SDK image itself is likely amd64
FROM --platform=linux/amd64 ${REPO}/${SDK}:${SDK_VERSION}-${ACAP_ARCH_TAG} AS acap_packager

# Expose ARGs passed from build.sh to this stage
ARG REPO
ARG SDK
ARG APP_USERNAME
ARG ACAP_ARCH_TAG
ARG TAILSCALE_UP_OPTS
ARG SDK_VERSION
ARG UPX_COMPRESS

RUN echo ">>> ACAP Packager Args: REPO=${REPO}, SDK=${SDK}, SDK_VERSION=${SDK_VERSION}, ACAP_ARCH_TAG=${ACAP_ARCH_TAG}, APP_USERNAME=${APP_USERNAME:-<none>}, TAILSCALE_UP_OPTS='${TAILSCALE_UP_OPTS}', UPX_COMPRESS=${UPX_COMPRESS}"

WORKDIR /opt/app

# Copy application files (manifest, run script, CGI, html, etc.)
COPY ./app /opt/app/

# Ensure a clean lib directory before inserting the binary
RUN rm -rf /opt/app/lib && mkdir -p /opt/app/lib

COPY --from=builder /out/tailscaled /opt/app/lib/tailscaled
COPY --from=builder /out/tailscale_version.txt /tmp/tailscale_version.txt
COPY --from=builder /out/build_tags.txt /tmp/build_tags.txt

# Provide the conventional "tailscale" name for interactive use. The symlink is
# created here rather than copied so it is stored as a symlink regardless of how
# COPY resolves links. Nothing in the package depends on it: the start script
# and the CGI both select the CLI with TS_BE_CLI, which works even if the
# on-device installer flattens or drops symlinks.
RUN ln -s tailscaled /opt/app/lib/tailscale

# Install jq and sed
RUN apt-get update && apt-get install -y --no-install-recommends jq sed && rm -rf /var/lib/apt/lists/*

# Calculate, log, and save all dynamic variables to temp files
RUN export RAW_TS_VERSION=$(cat /tmp/tailscale_version.txt) && \
    export CLEAN_TS_VERSION=$(echo "${RAW_TS_VERSION}" | sed -n 's/^v*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p') && \
    if [ -z "${CLEAN_TS_VERSION}" ]; then CLEAN_TS_VERSION="${RAW_TS_VERSION}"; fi && \
    TAILSCALED_EXTRA_ARGS="" && \
    if [ "${APP_USERNAME}" != "root" ]; then \
        TAILSCALED_EXTRA_ARGS="--tun=userspace-networking"; \
    fi && \
    FINAL_TS_UP_OPTS=$(echo "${TAILSCALE_UP_OPTS}" | xargs) && \
    echo "== Variable Calculation Step ==" && \
    echo "RAW_TS_VERSION=${RAW_TS_VERSION}" && \
    echo "CLEAN_TS_VERSION=${CLEAN_TS_VERSION}" && \
    echo "TAILSCALED_EXTRA_ARGS=${TAILSCALED_EXTRA_ARGS}" && \
    echo "FINAL_TS_UP_OPTS=${FINAL_TS_UP_OPTS}" && \
    echo "BUILD_TAGS=$(cat /tmp/build_tags.txt)" && \
    echo "=============================" && \
    echo "${CLEAN_TS_VERSION}" > /tmp/var_clean_ts_version && \
    echo "${TAILSCALED_EXTRA_ARGS}" > /tmp/var_ts_daemon_args && \
    echo "${FINAL_TS_UP_OPTS}" > /tmp/var_ts_up_opts

# Update manifest.json: version, architecture, optional user, and the CGI
# declaration that lets the settings page read live daemon status.
RUN set -e; \
    export CLEAN_TS_VERSION=$(cat /tmp/var_clean_ts_version); \
    echo "--- Updating manifest.json with Version: ${CLEAN_TS_VERSION}, Arch: ${ACAP_ARCH_TAG}, User: ${APP_USERNAME:-<none>}, SDK: ${SDK_VERSION}"; \
    if [ "${APP_USERNAME}" = "" ]; then \
       echo "--- Removing user object from manifest as no user was specified"; \
       jq --arg ver "${CLEAN_TS_VERSION}" \
          --arg arch "${ACAP_ARCH_TAG}" \
          '.schemaVersion = "1.6.0" | .acapPackageConf.setup |= (.version = $ver | .architecture = $arch | del(.user))' \
          /opt/app/manifest.json > /tmp/manifest.json.tmp; \
    else \
       echo "--- Updating manifest with user: ${APP_USERNAME}"; \
       jq --arg ver "${CLEAN_TS_VERSION}" \
          --arg arch "${ACAP_ARCH_TAG}" \
          --arg user "${APP_USERNAME}" \
          --arg group "${APP_USERNAME}" \
          '.schemaVersion = "1.6.0" | .acapPackageConf.setup |= (.version = $ver | .architecture = $arch | .user.username = $user | .user.group = $group)' \
          /opt/app/manifest.json > /tmp/manifest.json.tmp; \
    fi; \
    mv /tmp/manifest.json.tmp /opt/app/manifest.json

RUN chmod +x /opt/app/Tailscale /opt/app/status.cgi

# Inject tailscaled daemon arguments from saved file
RUN export DAEMON_ARGS=$(cat /tmp/var_ts_daemon_args) && \
    echo "--- Injecting tailscaled args '${DAEMON_ARGS}' into /opt/app/Tailscale via placeholder ---" && \
    sed -i "s%__TAILSCALED_ARGS__%${DAEMON_ARGS}%" /opt/app/Tailscale

# Inject tailscale up arguments from saved file
RUN export UP_ARGS=$(cat /tmp/var_ts_up_opts) && \
    echo "--- Injecting tailscale up args: '${UP_ARGS}' into /opt/app/Tailscale up line ---" && \
    sed -i "s%__TAILSCALE_ARGS__%${UP_ARGS}%" /opt/app/Tailscale

# Copy final version file, log binary size, set permissions, and clean up
RUN cp /tmp/tailscale_version.txt /opt/app/tailscale_version.txt && \
    echo "--- Size of the combined Tailscale binary:" && \
    du -h /opt/app/lib/tailscaled && \
    chmod 755 /opt/app/lib/tailscaled && \
    rm /tmp/tailscale_version.txt /tmp/build_tags.txt /tmp/var_clean_ts_version /tmp/var_ts_daemon_args /tmp/var_ts_up_opts

# Run the ACAP build process.
#
# status.cgi must be passed with -a: the manifest's httpConfig entry only
# generates cgi.conf (the access-control file), it does not add the script
# itself to the package. Without -a the CGI is declared but missing at runtime.
#
# The two tailscale_up_opts.txt / tailscale_authkey placeholders are shipped
# empty so that tools/eap-inject.sh can stamp a device-specific auth key into a
# finished package by rewriting existing package members, rather than adding
# files the package manifest never declared.
RUN . /opt/axis/acapsdk/environment-setup* && \
    echo "--- Debugging before acap-build ---" && \
    echo "Current directory: $(pwd)" && \
    echo "Directory contents:" && \
    ls -la && \
    echo "Contents of manifest.json:" && \
    cat manifest.json && \
    echo "-------------------------------------" && \
    echo "DEBUG: Running acap-build with Arch='${ACAP_ARCH_TAG}', User='${APP_USERNAME:-<none>}'" && \
    acap-build . -a status.cgi -a tailscale_up_opts.txt -a tailscale_authkey
