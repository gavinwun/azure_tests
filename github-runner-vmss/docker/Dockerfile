# Runner image for the ACI backend - equivalent of what bootstrap_agent.sh
# installs directly onto Ubuntu for the VMSS backend, packaged as a
# container instead. Same tool list, same GitHub Actions runner binary.

FROM ubuntu:22.04

ARG RUNNER_VERSION=2.321.0
ENV DEBIAN_FRONTEND=noninteractive

# --- Base packages + tooling (mirrors bootstrap_agent.sh sections 1-5) ---
RUN apt-get update && apt-get install -y \
      curl jq zip unzip ca-certificates apt-transport-https gnupg \
      lsb-release git build-essential libicu-dev sudo \
    && rm -rf /var/lib/apt/lists/*

# Node.js (NodeSource LTS)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Azure CLI
RUN curl -sL https://packages.microsoft.com/keys/microsoft.asc \
      | gpg --dearmor | tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null \
    && AZ_REPO=$(lsb_release -cs) \
    && echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ ${AZ_REPO} main" \
      | tee /etc/apt/sources.list.d/azure-cli.list \
    && apt-get update && apt-get install -y azure-cli \
    && rm -rf /var/lib/apt/lists/*

# .NET SDK
RUN UBUNTU_VER=$(lsb_release -rs) \
    && wget "https://packages.microsoft.com/config/ubuntu/${UBUNTU_VER}/packages-microsoft-prod.deb" \
      -O /tmp/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb && rm /tmp/packages-microsoft-prod.deb \
    && apt-get update && apt-get install -y dotnet-sdk-8.0 \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI - only needed if your workflows build/run containers on the
# runner itself. Omit this layer if not; running Docker-in-Docker inside
# ACI additionally requires the container group's securityContext to
# allow privileged mode, which isn't set up here - add it only if needed.
RUN apt-get update && apt-get install -y docker.io && rm -rf /var/lib/apt/lists/*

# --- GitHub Actions runner binary ---
RUN mkdir -p /opt/actions-runner
WORKDIR /opt/actions-runner
RUN curl -o actions-runner-linux-x64.tar.gz -L \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    && tar xzf actions-runner-linux-x64.tar.gz \
    && rm actions-runner-linux-x64.tar.gz \
    && ./bin/installdependencies.sh

RUN useradd -m -s /bin/bash actions-runner \
    && chown -R actions-runner:actions-runner /opt/actions-runner \
    && echo "actions-runner ALL=(ALL) NOPASSWD: /opt/actions-runner/svc.sh" >> /etc/sudoers

COPY entrypoint.sh /opt/actions-runner/entrypoint.sh
RUN chmod +x /opt/actions-runner/entrypoint.sh

# Runs as root at container start so entrypoint.sh can call IMDS for the
# managed-identity token; it drops to the actions-runner user itself for
# config.sh/run.sh, same separation bootstrap_agent.sh uses on the VMSS side.
ENTRYPOINT ["/opt/actions-runner/entrypoint.sh"]
