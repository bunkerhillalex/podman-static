# Download gpg
FROM alpine:3.15 AS gpg
RUN apk add --no-cache gnupg


# runc
FROM golang:1.18-alpine3.15 AS runc
ARG RUNC_VERSION=v1.1.4
RUN set -eux; \
	apk add --no-cache --virtual .build-deps gcc musl-dev libseccomp-dev libseccomp-static make git bash; \
	git clone -c 'advice.detachedHead=false' --depth=1 --branch ${RUNC_VERSION} https://github.com/opencontainers/runc src/github.com/opencontainers/runc; \
	cd src/github.com/opencontainers/runc; \
	make static BUILDTAGS='seccomp selinux ambient'; \
	mv runc /usr/local/bin/runc; \
	rm -rf $GOPATH/src/github.com/opencontainers/runc; \
	apk del --purge .build-deps; \
	[ "$(ldd /usr/local/bin/runc | wc -l)" -eq 0 ] || (ldd /usr/local/bin/runc; false)


# podman build base
FROM golang:1.18-alpine3.15 AS podmanbuildbase
RUN apk add --update --no-cache git make gcc pkgconf musl-dev \
	btrfs-progs btrfs-progs-dev libassuan-dev lvm2-dev device-mapper \
	glib-static libc-dev gpgme-dev protobuf-dev protobuf-c-dev \
	libseccomp-dev libseccomp-static libselinux-dev ostree-dev openssl iptables \
	bash go-md2man


# podman (without systemd support)
FROM podmanbuildbase AS podman
RUN apk add --update --no-cache tzdata curl
ARG PODMAN_VERSION=v4.2.1
ARG PODMAN_BUILDTAGS='seccomp selinux apparmor exclude_graphdriver_devicemapper containers_image_openpgp'
ARG PODMAN_CGO=1
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch ${PODMAN_VERSION} https://github.com/containers/podman src/github.com/containers/podman
WORKDIR $GOPATH/src/github.com/containers/podman
RUN set -ex; \
	export CGO_ENABLED=$PODMAN_CGO; \
	make bin/podman LDFLAGS_PODMAN="-s -w -extldflags '-static'" BUILDTAGS='${PODMAN_BUILDTAGS}'; \
	mv bin/podman /usr/local/bin/podman; \
	podman --help >/dev/null; \
	[ "$(ldd /usr/local/bin/podman | wc -l)" -eq 0 ] || (ldd /usr/local/bin/podman; false)
RUN set -ex; \
	CGO_ENABLED=0 make bin/rootlessport BUILDFLAGS=" -mod=vendor -ldflags=\"-s -w -extldflags '-static'\""; \
	mkdir -p /usr/local/lib/podman; \
	mv bin/rootlessport /usr/local/lib/podman/rootlessport; \
	[ "$(ldd /usr/local/lib/podman/rootlessport | wc -l)" -eq 0 ] || (ldd /usr/local/lib/podman/rootlessport; false)


# conmon (without systemd support)
FROM podmanbuildbase AS conmon
ARG CONMON_VERSION=v2.1.4
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch ${CONMON_VERSION} https://github.com/containers/conmon.git /conmon
WORKDIR /conmon
RUN set -ex; \
	make git-vars bin/conmon PKG_CONFIG='pkg-config --static' CFLAGS='-std=c99 -Os -Wall -Wextra -Werror -static' LDFLAGS='-s -w -static'; \
	bin/conmon --help >/dev/null


# CNI plugins
FROM podmanbuildbase AS cniplugins
ARG CNI_PLUGIN_VERSION=v1.1.1
ARG CNI_PLUGINS="ipam/host-local main/loopback main/bridge meta/portmap meta/tuning meta/firewall"
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${CNI_PLUGIN_VERSION} https://github.com/containernetworking/plugins /go/src/github.com/containernetworking/plugins
WORKDIR /go/src/github.com/containernetworking/plugins
RUN set -ex; \
	for PLUGINDIR in $CNI_PLUGINS; do \
		PLUGINBIN=/usr/local/lib/cni/$(basename $PLUGINDIR); \
		CGO_ENABLED=0 go build -o $PLUGINBIN -ldflags "-s -w -extldflags '-static'" ./plugins/$PLUGINDIR; \
		[ "$(ldd $PLUGINBIN | grep -Ev '^\s+ldd \(0x[0-9a-f]+\)$' | wc -l)" -eq 0 ] || (ldd $PLUGINBIN; false); \
	done


# slirp4netns
FROM podmanbuildbase AS slirp4netns
WORKDIR /
RUN apk add --update --no-cache autoconf automake meson ninja linux-headers libcap-static libcap-dev clang llvm
# Build libslirp
ARG LIBSLIRP_VERSION=v4.7.0
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=${LIBSLIRP_VERSION} https://gitlab.freedesktop.org/slirp/libslirp.git
WORKDIR /libslirp
RUN set -ex; \
	rm -rf /usr/lib/libglib-2.0.so /usr/lib/libintl.so; \
	ln -s /usr/bin/clang /go/bin/clang; \
	LDFLAGS="-s -w -static" meson --prefix /usr -D default_library=static build; \
	ninja -C build install
# Build slirp4netns
WORKDIR /
ARG SLIRP4NETNS_VERSION=v1.2.0
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch $SLIRP4NETNS_VERSION https://github.com/rootless-containers/slirp4netns.git
WORKDIR /slirp4netns
RUN set -ex; \
	./autogen.sh; \
	LDFLAGS=-static ./configure --prefix=/usr; \
	make


# fuse-overlayfs (derived from https://github.com/containers/fuse-overlayfs/blob/master/Dockerfile.static)
FROM podmanbuildbase AS fuse-overlayfs
RUN apk add --update --no-cache autoconf automake meson ninja clang g++ eudev-dev fuse3-dev
ARG LIBFUSE_VERSION=fuse-3.12.0
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=$LIBFUSE_VERSION https://github.com/libfuse/libfuse /libfuse
WORKDIR /libfuse
RUN set -ex; \
	mkdir build; \
	cd build; \
	LDFLAGS="-lpthread -s -w -static" meson --prefix /usr -D default_library=static .. || (cat /libfuse/build/meson-logs/meson-log.txt; false); \
	ninja; \
	touch /dev/fuse; \
	ninja install; \
	fusermount3 -V
ARG FUSEOVERLAYFS_VERSION=v1.9
RUN git clone -c 'advice.detachedHead=false' --depth=1 --branch=$FUSEOVERLAYFS_VERSION https://github.com/containers/fuse-overlayfs /fuse-overlayfs
WORKDIR /fuse-overlayfs
RUN set -ex; \
	sh autogen.sh; \
	LIBS="-ldl" LDFLAGS="-s -w -static" ./configure --prefix /usr; \
	make; \
	make install; \
	fuse-overlayfs --help >/dev/null


# Build podman base image
FROM alpine:3.15 AS podmanbase
LABEL maintainer="Max Goltzsche <max.goltzsche@gmail.com>"
RUN apk add --no-cache tzdata ca-certificates
COPY --from=conmon /conmon/bin/conmon /usr/local/lib/podman/conmon
COPY --from=podman /usr/local/lib/podman/rootlessport /usr/local/lib/podman/rootlessport
COPY --from=podman /usr/local/bin/podman /usr/local/bin/podman
COPY conf/containers /etc/containers
RUN set -ex; \
	adduser -D podman -h /podman -u 1000; \
	echo 'podman:100000:65536' > /etc/subuid; \
	echo 'podman:100000:65536' > /etc/subgid; \
	ln -s /usr/local/bin/podman /usr/bin/docker; \
	mkdir -p /podman/.local/share/containers/storage /var/lib/containers/storage; \
	chown -R podman:podman /podman; \
	mkdir -m1777 /.local /.config /.cache; \
	podman --help >/dev/null; \
	/usr/local/lib/podman/conmon --help >/dev/null
ENV _CONTAINERS_USERNS_CONFIGURED=""

# Build rootless podman base image (without OCI runtime)
FROM podmanbase AS rootlesspodmanbase
ENV BUILDAH_ISOLATION=chroot container=oci
RUN apk add --no-cache shadow-uidmap
COPY --from=fuse-overlayfs /usr/bin/fuse-overlayfs /usr/local/bin/fuse-overlayfs
COPY --from=fuse-overlayfs /usr/bin/fusermount3 /usr/local/bin/fusermount3

# Build rootless podman base image with runc
FROM rootlesspodmanbase AS rootlesspodmanrunc
COPY --from=runc   /usr/local/bin/runc   /usr/local/bin/runc

# Download crun
# (switched keyserver from sks to ubuntu since sks is offline now and gpg refuses to import keys from keys.openpgp.org because it does not provide a user ID with the key.)
FROM gpg AS crun
ARG CRUN_VERSION=1.6
RUN set -ex; \
	wget -O /usr/local/bin/crun https://github.com/containers/crun/releases/download/$CRUN_VERSION/crun-${CRUN_VERSION}-linux-amd64-disable-systemd; \
	wget -O /tmp/crun.asc https://github.com/containers/crun/releases/download/$CRUN_VERSION/crun-${CRUN_VERSION}-linux-amd64-disable-systemd.asc; \
	gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 027F3BD58594CA181BB5EC50E4730F97F60286ED; \
	gpg --batch --verify /tmp/crun.asc /usr/local/bin/crun; \
	chmod +x /usr/local/bin/crun; \
	crun --help >/dev/null

# Build minimal rootless podman
FROM rootlesspodmanbase AS rootlesspodmanminimal
COPY --from=crun /usr/local/bin/crun /usr/local/bin/crun
COPY conf/crun-containers.conf /etc/containers/containers.conf

# Build podman image with rootless binaries and CNI plugins
FROM rootlesspodmanrunc AS podmanall
RUN apk add --no-cache iptables ip6tables
COPY --from=slirp4netns /slirp4netns/slirp4netns /usr/local/bin/slirp4netns
COPY --from=cniplugins /usr/local/lib/cni /usr/local/lib/cni
COPY conf/cni /etc/cni
