# Copyright 2021 Synology Inc.

############## Build stage ##############
FROM golang:1.27.1-alpine AS builder
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
# Alpine, not UBI9/RHEL9: measured via Trivy against the identical
# source and Go 1.27.1 builder above, this final stage scans at 0
# findings vs. 388 (17 High, 246 Medium, 125 Low - all with no vendor
# fix published) for the UBI9-minimal + RHEL-entitled-RPMs final stage
# used on fix/bump-go-1.25-cve-fixes. This branch trades upstream's
# OpenShift/Red Hat certification base for that CVE reduction - it does
# not track upstream's UBI9 final stage and needs no RHEL entitlement
# or subscription-manager credentials to build.
FROM alpine:latest
LABEL maintainers="Synology Authors" \
      description="Synology CSI Plugin"

# blkid is provided by util-linux. btrfs-progs restores StorageClass
# `fsType: btrfs` support (mkfs runs inside the container, see
# pkg/driver/nodeserver.go NodeStageVolume) - RHEL 9 dropped btrfs
# entirely, but Alpine still packages it.
RUN apk add --no-cache e2fsprogs e2fsprogs-extra xfsprogs xfsprogs-extra blkid util-linux iproute2 bash btrfs-progs ca-certificates cifs-utils nfs-utils nvme-cli

WORKDIR /

# Copy and run CSI driver
COPY --from=builder /go/src/synok8scsiplugin/bin/synology-csi-driver synology-csi-driver

ENTRYPOINT ["/synology-csi-driver"]
