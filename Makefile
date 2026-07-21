REGISTRY ?= amitactive2008
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
		--driver-opt=cacert=/certs/ca.pem,cert=/certs/cert.pem,key=/certs/key.pem \
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

