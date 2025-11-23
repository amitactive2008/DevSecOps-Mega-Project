REGISTRY ?= ayaan49
VERSION ?= latest
PLATFORM ?= linux/amd64,linux/arm64
BUILD ?= $(shell date +%Y%m%d%H%M%S)
BUILDKIT_HOST = tcp://buildkitd:1234

.PHONY: builder client api

builder:
	 docker buildx create \
		--name imagebuilder \
		--driver=remote \
		$(BUILDKIT_HOST) \
		--bootstrap --use || true

client: builder
	 docker buildx build \
		--platform $(PLATFORM) \
		-f client/Dockerfile \
		-t $(REGISTRY)/client:$(VERSION) \
		client/ \
		--push

api: builder
	 docker buildx build \
		--platform $(PLATFORM) \
		-f api/Dockerfile \
		-t $(REGISTRY)/api:$(VERSION) \
		api/ \
		--push

