FROM python:3.9-slim-buster AS builder
# staticx has two issues:
# 1. It does not seem to play well with alpine (at least for Python+pie).
#    In that configuration, it seems to think it's a glibc executable
# 2. It does not play well with PIE executables, see
#       https://github.com/JonathonReinhart/staticx/issues/71

RUN true \
    && apt-get update                             \
    && apt-get install --no-install-recommends -y \
         build-essential=12.6                     \
         patchelf=0.9*                            \
         zlib1g-dev=1:1.2.11*                     \
    && pip3 install scons==4.0.1                  \
    && pip3 install pyinstaller==4.1              \
                    patchelf-wrapper==1.2.0       \
                    staticx==0.12.0               \
    && rm -rf /var/lib/apt/lists/*

ARG PYINSTALLER_TAG=v4.1

# HACK to get around https://github.com/JonathonReinhart/staticx/issues/71
RUN true \
    && apt-get update                                                     \
    && apt-get install --no-install-recommends -y                         \
          git=1:2.20*                                                     \
    && git clone --depth 1 --single-branch --branch ${PYINSTALLER_TAG}    \
          https://github.com/pyinstaller/pyinstaller.git /tmp/pyinstaller \
    && cd /tmp/pyinstaller/bootloader                                     \
    && CC="gcc -no-pie" python ./waf configure --no-lsb all               \
    && cp -R /tmp/pyinstaller/PyInstaller/bootloader/*                    \
             /usr/local/lib/python*/site-packages/PyInstaller/bootloader/ \
    && rm -rf /var/lib/apt/lists/*

# # ENTRYPOINT ["etags.py"]
#
COPY requirements.txt /src/
COPY etags.py /src/

WORKDIR /src

# We use find here because different architectures might be wildly different.
# The specific directory is named by the gcc toolchain, which doesn't really
# line up here with uname -m. As an example, 32 bit arm libraries can be the
# same across arm versions (arm7/arm8 32 bit)
# x86_64: /lib/x86_64-linux-gnu
# arm64: /lib/aarch64-linux-gnu
# arm7: /lib/arm-linux-gnueabihf
RUN true                                                     \
    && pip3 install -r requirements.txt                      \
    && pyinstaller -F etags.py                               \
    && staticx                                               \
         --strip                                             \
         --no-compress                                       \
         -l "$(find /lib -name libgcc_s.so.1 -print -quit)"  \
         dist/etags dist/app                                 \
    && chmod 755 dist/app

FROM scratch

# Allow ssl comms
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# So we can set the user
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group

# This should need no privileges
USER nobody:nogroup

# Environment variables that should be set
ENV AWS_DEFAULT_REGION=us-west-2
ENV AWS_ACCESS_KEY_ID=AKIAEXAMPLE
ENV AWS_SECRET_ACCESS_KEY=dummy
# Set if you're not talking to real DDB
# ENV DDB_ENDPOINT
ENV ETAGS_TABLE=etags
# Setting this variable to nothing will turn off bus notification
ENV ETAGS_BUS_NAME=

ENTRYPOINT ["/app"]

ADD tmp.tar.gz /
COPY --from=builder /src/dist/app /app
