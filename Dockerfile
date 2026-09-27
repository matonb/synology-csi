# Copyright 2021 Synology Inc.

############## Build stage ##############
FROM golang:1.25.13-alpine as builder
LABEL stage=synobuilder

RUN apk add --no-cache alpine-sdk
WORKDIR /go/src/synok8scsiplugin
COPY go.mod go.sum ./
RUN go mod download

COPY Makefile .

ARG TARGETPLATFORM

COPY main.go .
COPY pkg ./pkg
COPY synocli ./synocli
RUN env GOARCH=$(echo "$TARGETPLATFORM" | cut -f2 -d/) \
        GOARM=$(echo "$TARGETPLATFORM" | cut -f3 -d/ | cut -c2-) \
        make

############## Final stage ##############
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

ARG IMAGE_VERSION=dev
ARG IMAGE_RELEASE=1
LABEL name="synology-csi" \
      maintainer="Synology" \
      vendor="Synology Inc." \
      version="${IMAGE_VERSION}" \
      release="${IMAGE_RELEASE}" \
      summary="Synology CSI driver for Kubernetes" \
      description="A Container Storage Interface (CSI) driver for Synology NAS."

# Runtime tools. blkid is provided by util-linux.
#
# btrfs-progs (present in the old Alpine image) is intentionally omitted, which
# drops support for StorageClass `fsType: btrfs` (mkfs runs inside the container,
# see pkg/driver/nodeserver.go NodeStageVolume). Rationale: RHEL 9 removed btrfs
# entirely — no kernel module and no btrfs-progs package — so on RHCOS/OpenShift
# the filesystem could not be mounted even if we shipped the tools, and the UBI/
# RHEL repos have no package to install. Note this IS a behavior change for
# non-RHEL nodes whose kernels support btrfs; it must be called out in the docs/
# release notes. DSM-side btrfs volumes (BLUN location) are unaffected — that is
# an API-level attribute and needs no local tools.
#
# NOTE: e2fsprogs, xfsprogs, nfs-utils and cifs-utils are NOT in the free UBI
# repos; they live in the full RHEL 9 repos. This build therefore requires RHEL
# entitlement. Red Hat's own certification build service injects this
# transparently; anyone else building this Dockerfile needs to supply RH
# credentials as BuildKit secrets `rh_username`/`rh_password` (e.g. a free
# Red Hat Developer Subscription, which uses Simple Content Access - no
# --auto-attach/pool needed, but the RHEL repos still have to be explicitly
# enabled since microdnf doesn't run the subscription-manager dnf plugin that
# would otherwise write them out). subscription-manager is installed,
# registered, used, and removed within this single RUN so no entitlement
# material or subscription state persists in the image; cleanup runs even if
# the install fails, so a failed build doesn't leak a registered system.
RUN --mount=type=secret,id=rh_username,required=true \
    --mount=type=secret,id=rh_password,required=true \
    microdnf install -y subscription-manager \
    && subscription-manager register \
        --username="$(cat /run/secrets/rh_username)" \
        --password="$(cat /run/secrets/rh_password)" \
    && subscription-manager refresh \
    && subscription-manager repos \
        --enable=rhel-9-for-$(uname -m)-baseos-rpms \
        --enable=rhel-9-for-$(uname -m)-appstream-rpms \
    && microdnf install -y \
        e2fsprogs xfsprogs util-linux iproute bash \
        ca-certificates cifs-utils nfs-utils nvme-cli; \
    rc=$?; \
    subscription-manager unregister || true; \
    subscription-manager clean || true; \
    microdnf remove -y subscription-manager python3-subscription-manager-rhsm \
        subscription-manager-rhsm-certificates libdnf-plugin-subscription-manager || true; \
    microdnf clean all; \
    exit $rc

# Red Hat certification requires a /licenses directory in the image.
COPY LICENSE /licenses/LICENSE

WORKDIR /

# Copy and run CSI driver
COPY --from=builder /go/src/synok8scsiplugin/bin/synology-csi-driver synology-csi-driver

# Declare a non-root user to satisfy the RunAsNonRoot certification check.
# The node DaemonSet still runs privileged with runAsUser: 0 (mount / iscsiadm
# need root); the controller Deployment can run as this user.
USER 1000

ENTRYPOINT ["/synology-csi-driver"]
