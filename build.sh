#!/usr/bin/env sh
docker=docker
if command -v balena >/dev/null 2>&1;then
	docker=balena
fi
if [ -n "$https_proxy" ];then
	build_extra_args="--build-arg https_proxy=$https_proxy"
fi
$docker build $build_extra_args --build-arg BALENA_ARCH=aarch64 . -f Dockerfile.template -t cellular_guard
