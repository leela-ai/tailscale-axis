# Global ARG declarations - must be at the top, before ANY FROM statement
ARG GO_VERSION=1.24
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

# === Stage 1: Build & Compress Tailscale Binaries ===
FROM golang:${GO_VERSION} AS builder

# Expose the architecture settings to this stage
ARG GOOS
ARG GOARCH
ARG GOARM
ARG TAILSCALE_VERSION=latest

# Install build dependencies: git, build tools, curl, jq
RUN set -eux; \
    apt-get update; \
    apt-get install -y \
        git \
        build-essential \
        gcc \
        make \
        g++ \
        cmake \
        libucl-dev \
        zlib1g-dev \
        ca-certificates \
        file \
        curl \
        jq; \
    rm -rf /var/lib/apt/lists/*;

WORKDIR /src

# Clone the full Tailscale repository
RUN git clone https://github.com/tailscale/tailscale.git

# Change working directory into the cloned source code
WORKDIR /src/tailscale

# Determine the target version: Use provided TAILSCALE_VERSION arg,
# otherwise fetch the latest *release* tag from GitHub API.
RUN set -eux; \
    TARGET_TAG=""; \
    # Check if a specific version is requested via build arg
    if [ -n "${TAILSCALE_VERSION}" ] && [ "${TAILSCALE_VERSION}" != "latest" ]; then \
      TARGET_TAG="${TAILSCALE_VERSION}"; \
      echo ">>> Using specified Tailscale tag: $TARGET_TAG"; \
      # Fetch the specific tag if needed (might not be in initial clone)
      echo "Fetching specific tag $TARGET_TAG..."; \
      # Use shallow fetch for specific tags to save time/bandwidth
      git fetch --depth 1 origin "refs/tags/$TARGET_TAG"; \
    else \
      echo ">>> Fetching latest stable release tag from GitHub API..."; \
      # Use GitHub API to find the latest non-prerelease, non-draft release
      # -f (--fail) makes curl exit non-zero on server error (e.g., 404)
      # -s (--silent) hides progress meter
      # -L (--location) follows redirects
      API_URL="https://api.github.com/repos/tailscale/tailscale/releases/latest"; \
      LATEST_RELEASE_TAG=$(curl -sfSL "${API_URL}" | jq -r .tag_name); \
      # Check if API call succeeded and returned a valid tag (starts with v)
      if [ $? -eq 0 ] && [ -n "$LATEST_RELEASE_TAG" ] && [ "$(echo $LATEST_RELEASE_TAG | cut -c1)" = "v" ]; then \
        TARGET_TAG="$LATEST_RELEASE_TAG"; \
        echo ">>> Using latest stable release tag from GitHub API: $TARGET_TAG"; \
        # Fetch the specific tag if needed (might not be in initial clone)
        echo "Fetching specific tag $TARGET_TAG..."; \
        git fetch --depth 1 origin "refs/tags/$TARGET_TAG"; \
      else \
        # Fallback: If API fails or returns unexpected format, use the old git tag logic
        echo "!!! GitHub API failed (curl exit code $?), returned tag '$LATEST_RELEASE_TAG'. Falling back to git tag logic..."; \
        # Ensure all tags are available locally for fallback
        git fetch --tags --force; \
        TARGET_TAG=$(git tag -l 'v*' --sort=-v:refname | grep -v -E 'rc|beta|alpha' | head -n 1); \
        if [ -z "$TARGET_TAG" ]; then \
            echo "!!! Could not find latest stable tag via git. Finding absolute latest tag..."; \
            TARGET_TAG=$(git describe --tags $(git rev-list --tags --max-count=1)); \
        fi; \
        if [ -z "$TARGET_TAG" ]; then \
            echo "!!! FATAL: Could not determine any latest tag via git fallback."; exit 1; \
        fi; \
        echo ">>> Using latest tag found via git fallback: $TARGET_TAG"; \
      fi; \
    fi; \
    # Checkout the determined tag
    echo ">>> Checking out $TARGET_TAG..."; \
    git checkout "$TARGET_TAG";

# Build tailscale and tailscaled with maximum size optimizations
#   -s -w : strip symbol table & DWARF info
#   -buildid= : omits buildid (a few KB)
#   -trimpath : removes GOPATH and module root prefixes from file paths
#   CGO_ENABLED=0 ensures fully static pure-Go binary (smaller & no libc dependency)
ENV LD_FLAGS="-s -w -buildid="

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg \
    GOOS=${GOOS} GOARCH=${GOARCH} GOARM=${GOARM} CGO_ENABLED=0 go build -v -trimpath -ldflags="$LD_FLAGS" -o /out/tailscale ./cmd/tailscale && \
    GOOS=${GOOS} GOARCH=${GOARCH} GOARM=${GOARM} CGO_ENABLED=0 go build -v -trimpath -ldflags="$LD_FLAGS" -o /out/tailscaled ./cmd/tailscaled

# Verify the file type of the compiled binaries
RUN file /out/tailscale /out/tailscaled

# Capture the specific tailscale version built
RUN /out/tailscale version | cut -d ' ' -f 1 > /out/tailscale_version.txt && \
    echo "--- Captured Tailscale version: $(cat /out/tailscale_version.txt)"

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

# Log the arguments received by this stage
RUN echo ">>> ACAP Packager Args: REPO=${REPO}, SDK=${SDK}, SDK_VERSION=${SDK_VERSION}, ACAP_ARCH_TAG=${ACAP_ARCH_TAG}, APP_USERNAME=${APP_USERNAME:-<none>}, TAILSCALE_UP_OPTS='${TAILSCALE_UP_OPTS}'"

WORKDIR /opt/app

# Copy application files (manifest, run script, html, cgi-bin, etc.)
COPY ./app /opt/app/

# Ensure a clean lib directory before inserting new binaries
RUN rm -rf /opt/app/lib && mkdir -p /opt/app/lib

# Copy the built & compressed binaries from the builder stage
COPY --from=builder /out/tailscale /opt/app/lib/tailscale
COPY --from=builder /out/tailscaled /opt/app/lib/tailscaled

# Copy the captured version file
COPY --from=builder /out/tailscale_version.txt /tmp/tailscale_version.txt

# Install jq and sed
RUN apt-get update && apt-get install -y --no-install-recommends jq sed && rm -rf /var/lib/apt/lists/*

# Calculate, log, and save all dynamic variables to temp files
RUN export RAW_TS_VERSION=$(cat /tmp/tailscale_version.txt) && \
    # Calculate CLEAN_TS_VERSION
    export CLEAN_TS_VERSION=$(echo "${RAW_TS_VERSION}" | sed -n 's/^v*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p') && \
    if [ -z "${CLEAN_TS_VERSION}" ]; then CLEAN_TS_VERSION="${RAW_TS_VERSION}"; fi && \
    # Calculate TAILSCALED_EXTRA_ARGS
    TAILSCALED_EXTRA_ARGS="" && \
    if [ "${APP_USERNAME}" != "root" ]; then \
        TAILSCALED_EXTRA_ARGS="--tun=userspace-networking"; \
    fi && \
    # Calculate FINAL_TS_UP_OPTS
    FINAL_TS_UP_OPTS=$(echo "${TAILSCALE_UP_OPTS}" | xargs) && \
    # --- Log calculated values --- \
    echo "== Variable Calculation Step ==" && \
    echo "RAW_TS_VERSION=${RAW_TS_VERSION}" && \
    echo "CLEAN_TS_VERSION=${CLEAN_TS_VERSION}" && \
    echo "TAILSCALED_EXTRA_ARGS=${TAILSCALED_EXTRA_ARGS}" && \
    echo "FINAL_TS_UP_OPTS=${FINAL_TS_UP_OPTS}" && \
    echo "=============================" && \
    # --- Write variables to temp files --- \
    echo "${CLEAN_TS_VERSION}" > /tmp/var_clean_ts_version && \
    echo "${TAILSCALED_EXTRA_ARGS}" > /tmp/var_ts_daemon_args && \
    echo "${FINAL_TS_UP_OPTS}" > /tmp/var_ts_up_opts

# Update manifest.json using the saved clean version
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

# Make Tailscale script executable
RUN chmod +x /opt/app/Tailscale

# Inject tailscaled daemon arguments from saved file
RUN export DAEMON_ARGS=$(cat /tmp/var_ts_daemon_args) && \
    echo "--- Injecting tailscaled args '${DAEMON_ARGS}' into /opt/app/Tailscale via placeholder ---" && \
    sed -i "s%__TAILSCALED_ARGS__%${DAEMON_ARGS}%" /opt/app/Tailscale

# Inject tailscale up arguments from saved file
RUN export UP_ARGS=$(cat /tmp/var_ts_up_opts) && \
    echo "--- Injecting tailscale up args: '${UP_ARGS}' into /opt/app/Tailscale up line ---" && \
    sed -i "s%__TAILSCALE_ARGS__%${UP_ARGS}%" /opt/app/Tailscale

# Copy final version file, log binary sizes, set secure permissions, and cleanup temp files
RUN cp /tmp/tailscale_version.txt /opt/app/tailscale_version.txt && \
    echo "--- Size of Tailscale binaries:" && \
    du -sh /opt/app/lib/tailscale /opt/app/lib/tailscaled && \
    chmod 755 /opt/app/lib/tailscale /opt/app/lib/tailscaled && \
    rm /tmp/tailscale_version.txt /tmp/var_clean_ts_version /tmp/var_ts_daemon_args /tmp/var_ts_up_opts

# Run the ACAP build process
RUN . /opt/axis/acapsdk/environment-setup* && \
    echo "--- Debugging before acap-build ---" && \
    echo "Current directory: $(pwd)" && \
    echo "Directory contents:" && \
    ls -la && \
    echo "Contents of manifest.json:" && \
    cat manifest.json && \
    echo "-------------------------------------" && \
    echo "DEBUG: Running acap-build with Arch='${ACAP_ARCH_TAG}', User='${APP_USERNAME:-<none>}'" && \
    acap-build .
