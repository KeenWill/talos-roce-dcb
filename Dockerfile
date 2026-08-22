# syntax=docker/dockerfile:1.7

ARG ALPINE_IMAGE=alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

FROM ${ALPINE_IMAGE} AS service-rootfs

RUN apk add --no-cache iproute2 iproute2-rdma

COPY configure-roce-dcb /build/configure-roce-dcb

# The service runs in its own rootfs: busybox for the shell and the few
# utilities the script needs, plus dcb/rdma and the libraries they link.
RUN set -eux; \
    service_root=/extension-rootfs/usr/local/lib/containers/roce-dcb; \
    mkdir -p \
      "${service_root}/bin" \
      "${service_root}/etc" \
      "${service_root}/sbin" \
      "${service_root}/usr/local/sbin" \
      "${service_root}/usr/sbin"; \
    cp -a /bin/busybox "${service_root}/bin/busybox"; \
    ln -s busybox "${service_root}/bin/sh"; \
    ln -s busybox "${service_root}/bin/basename"; \
    ln -s busybox "${service_root}/bin/readlink"; \
    ln -s busybox "${service_root}/bin/sleep"; \
    for tool in dcb rdma; do \
      tool_path="$(command -v "${tool}")"; \
      cp -a "${tool_path}" "${service_root}${tool_path}"; \
    done; \
    cp -a /lib "${service_root}/lib"; \
    cp -a /usr/lib "${service_root}/usr/lib"; \
    if [ -d /etc/iproute2 ]; then cp -a /etc/iproute2 "${service_root}/etc/iproute2"; fi; \
    install -m 0755 /build/configure-roce-dcb "${service_root}/usr/local/sbin/configure-roce-dcb"; \
    find /extension-rootfs -type d -perm -0002 -exec chmod o-w {} +; \
    find /extension-rootfs -type f -perm -0002 -exec chmod o-w {} +

FROM scratch

COPY manifest.yaml /manifest.yaml
COPY roce-dcb.yaml /rootfs/usr/local/etc/containers/roce-dcb.yaml
COPY --from=service-rootfs /extension-rootfs/ /rootfs/
