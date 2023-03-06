#!/usr/bin/env sh
docker=docker
if command -v balena &>/dev/null;then
	docker=balena
fi
$docker build --build-arg BALENA_ARCH=aarch64 . -f Dockerfile.template -t cellular_guard
