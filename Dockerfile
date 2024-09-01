FROM debian:bookworm-slim as base

ENV LANG C.UTF-8

ARG GHC_VERSION=9.6.3
ARG STACK_VERSION=recommended
ARG STACK_RESOLVER=nightly
ARG CABAL_VERSION=recommended
ARG HLS_VERSION=recommended
ARG LLVM_VERSION=17

ENV USERNAME=vscode \
    USER_UID=1000 \
    USER_GID=1000 \
    DEBIAN_FRONTEND=noninteractive \
    GHC_VERSION=${GHC_VERSION} \
    STACK_VERSION=${STACK_VERSION} \
    STACK_RESOLVER=${STACK_RESOLVER} \
    CABAL_VERSION=${CABAL_VERSION} \
    HLS_VERSION=${HLS_VERSION} \
    LLVM_VERSION=${LLVM_VERSION}

RUN ulimit -n 8192

RUN VERSION_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d'=' -f2) && \
    apt-get update && \
    apt-get install -y --no-install-recommends software-properties-common wget && \
    # I don't know why, nor do I have any mental capacity to figure it out,
    # but we need to add the repository twice, otherwise it doesn't work (repo isn't being added)
    add-apt-repository -y -s -n "deb http://apt.llvm.org/${VERSION_CODENAME}/ llvm-toolchain-${VERSION_CODENAME}-${LLVM_VERSION} main" && \
    add-apt-repository -y -s -n "deb http://apt.llvm.org/${VERSION_CODENAME}/ llvm-toolchain-${VERSION_CODENAME}-${LLVM_VERSION} main" && \
    wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc && \
    apt-get update && \
    apt-get install -y --no-install-recommends apt-utils bash build-essential ca-certificates curl gcc git gnupg libffi-dev libffi8 libgmp-dev libgmp-dev libgmp10 libicu-dev libncurses-dev libncurses5 libnuma1 libnuma-dev libtinfo5 lsb-release make procps sudo xz-utils z3 zlib1g-dev clang-$LLVM_VERSION lldb-$LLVM_VERSION lld-$LLVM_VERSION clangd-$LLVM_VERSION

RUN groupadd --gid ${USER_GID} ${USERNAME} && \
    useradd -ms /bin/bash -K MAIL_DIR=/dev/null --uid ${USER_UID} --gid ${USER_GID} -m ${USERNAME} && \
    echo ${USERNAME} ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/${USERNAME} && \
    chmod 0440 /etc/sudoers.d/${USERNAME}

USER ${USER_UID}:${USER_GID}
WORKDIR /home/${USERNAME}
ENV PATH="/home/${USERNAME}/.local/bin:/home/${USERNAME}/.cabal/bin:/home/${USERNAME}/.ghcup/bin:$PATH"

RUN echo "export PATH=${PATH}" >> /home/${USERNAME}/.profile

ENV BOOTSTRAP_HASKELL_NONINTERACTIVE=yes \
    BOOTSTRAP_HASKELL_NO_UPGRADE=yes

FROM base as tooling

RUN curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

# Set the GHC version.
RUN ghcup install ghc ${GHC_VERSION} --set

# Install cabal-iinstall
RUN ghcup install cabal ${CABAL_VERSION} --set

# Update Cabal.
RUN cabal update && cabal new-install cabal-install

# Configure cabal
RUN cabal user-config update -f && \
    sed -i 's/-- ghc-options:/ghc-options: -haddock/g' ~/.cabal/config

# Install stack
RUN ghcup install stack ${STACK_VERSION} --set

# Set system-ghc, install-ghc and resolver for stack.
RUN ((stack ghc -- --version 2>/dev/null) || true) && \
    # Set global defaults for stack.
    stack config --system-ghc set system-ghc true --global && \
    stack config --system-ghc set install-ghc false --global && \
    stack config --system-ghc set resolver ${STACK_RESOLVER}

# Set global custom defaults for stack.
RUN printf "ghc-options:\n  \"\$everything\": -haddock\n" >> /home/${USERNAME}/.stack/config.yaml

# Install hls
RUN ghcup install hls ${HLS_VERSION} --set

FROM tooling as packages

# Install global packages.
# Versions are pinned, since we don't want to accidentally break anything (by always installing latest).
RUN cabal install --haddock-hoogle --minimize-conflict-set \
    fsnotify-0.4.1.0 \
    haskell-dap-0.0.16.0 \
    ghci-dap-0.0.22.0 \
    haskell-debug-adapter-0.0.39.0 \
    hlint-3.6.1 \
    apply-refact-0.14.0.0 \
    retrie-1.2.2 \
    hoogle-5.0.18.3 \
    ormolu-0.7.2.0

FROM packages as hoogle

# Generate hoogle db
RUN hoogle generate --download --haskell

ENV DEBIAN_FRONTEND=dialog

FROM hoogle as Customize

# 配置 GHCup 使用科大源。编辑 ~/.ghcup/config.yaml 增加如下配置：
RUN sed -i '$a\url-source:\n    OwnSource: https://mirrors.ustc.edu.cn/ghcup/ghcup-metadata/ghcup-0.0.7.yaml' ~/.ghcup/config.yaml

# 修改 ~/.cabal/config
RUN sed -i '/repository/s/hackage.haskell.org/mirrors.ustc.edu.cn/' ~/.cabal/config &&  sed -i '/url: /s/http:\/\/hackage.haskell.org\//https:\/\/mirrors.ustc.edu.cn\/hackage\//' ~/.cabal/config && sed -i '/secure/s/-- secure: True/secure: True/' ~/.cabal/config && head -n 20 ~/.cabal/config

# Stackage 镜像
RUN sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list.d/debian.sources
RUN mkdir -p ~/.stack/pantry/
RUN curl -o global-hints.yaml https://mirrors.ustc.edu.cn/stackage/stackage-content/stack/global-hints.yaml  && mv global-hints.yaml ~/.stack/pantry/global-hints-cache.yaml
RUN echo -e 'setup-info-locations:\n  - http://mirrors.ustc.edu.cn/stackage/stack-setup.yaml\nurls:\n  latest-snapshot: http://mirrors.ustc.edu.cn/stackage/snapshots.json\nsnapshot-location-base: http://mirrors.ustc.edu.cn/stackage/stackage-snapshots/' >> ~/.stack/config.yaml
RUN echo -e 'package-index:\n  download-prefix: https://mirrors.ustc.edu.cn/hackage/\n  hackage-security:\n    keyids:\n      - 0a5c7ea47cd1b15f01f5f51a33adda7e655bc0f0b0615baa8e271f4c3351e21d\n      - 1ea9ba32c526d1cc91ab5e5bd364ec5e9e8cb67179a471872f6e26f0ae773d42\n      - 280b10153a522681163658cb49f632cde3f38d768b736ddbc901d99a1a772833\n      - 2a96b1889dc221c17296fcc2bb34b908ca9734376f0f361660200935916ef201\n      - 2c6c3627bd6c982990239487f1abd02e08a02e6cf16edb105a8012d444d870c3\n      - 51f0161b906011b52c6613376b1ae937670da69322113a246a09f807c62f6921\n      - 772e9f4c7db33d251d5c6e357199c819e569d130857dc225549b40845ff0890d\n      - aa315286e6ad281ad61182235533c41e806e5a787e0b6d1e7eef3f09d137d2e9\n      - fe331502606802feac15e514d9b9ea83fee8b6ffef71335479a2e68d84adc6b0\n    key-threshold: 3 # number of keys required\n\n    # ignore expiration date, see https://github.com/commercialhaskell/stack/pull/4614\n    ignore-expiry: true' >> ~/.stack/config.yaml

ENTRYPOINT ["/bin/bash"]
