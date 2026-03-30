FROM ubuntu:24.04

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    jq \
    git \
    ca-certificates \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Copy forgeplan
COPY . /opt/forgeplan
RUN cd /opt/forgeplan && ./install.sh --prefix /usr/local

WORKDIR /workspace

ENTRYPOINT ["forgeplan"]
