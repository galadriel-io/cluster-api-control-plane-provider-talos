# syntax = docker/dockerfile-upstream:1.1.4-experimental

FROM golang:1.15 AS build
ENV GO111MODULE on
ENV GOPROXY https://proxy.golang.org
ENV CGO_ENABLED 0
WORKDIR /tmp
RUN go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.2.8
WORKDIR /src
COPY ./go.mod ./
COPY ./go.sum ./
RUN go mod download
RUN go mod verify
COPY ./ ./
RUN go list -mod=readonly all >/dev/null
RUN ! go mod tidy -v 2>&1 | grep .

FROM build AS manifests-build
ARG NAME
RUN controller-gen crd:crdVersions=v1 paths="./api/..." output:crd:dir=config/crd/bases output:webhook:dir=config/webhook webhook
RUN controller-gen rbac:roleName=manager-role paths="./controllers/..." output:rbac:dir=config/rbac
FROM scratch AS manifests
COPY --from=manifests-build /src/config/crd /config/crd
COPY --from=manifests-build /src/config/rbac /config/rbac

FROM build AS generate-build
RUN controller-gen object:headerFile=./hack/boilerplate.go.txt paths="./..."
FROM scratch AS generate
COPY --from=generate-build /src/api /api

FROM k8s.gcr.io/hyperkube:v1.17.0 AS release-build
RUN apt update -y \
  && apt install -y curl \
  && curl -LO https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv4.0.5/kustomize_v4.0.5_linux_arm64.tar.gz \
  && tar -xf kustomize_v4.0.5_linux_arm64.tar.gz -C /usr/local/bin \
  && rm kustomize_v4.0.5_linux_arm64.tar.gz
COPY ./config ./config
ARG REGISTRY_AND_USERNAME
ARG NAME
ARG TAG
RUN cd config/manager \
  && kustomize edit set image controller=${REGISTRY_AND_USERNAME}/${NAME}:${TAG} \
  && cd - \
  && kustomize build config >/control-plane-components.yaml \
  && cp config/metadata/metadata.yaml /metadata.yaml

FROM scratch AS release
COPY --from=release-build /control-plane-components.yaml /control-plane-components.yaml
COPY --from=release-build /metadata.yaml /metadata.yaml

FROM build AS binary
RUN --mount=type=cache,target=/root/.cache/go-build GOARCH=arm64 GOOS=linux go build -ldflags "-s -w" -o /manager
RUN chmod +x /manager

FROM scratch AS container
COPY --from=docker.io/autonomy/ca-certificates:v0.1.0 / /
COPY --from=docker.io/autonomy/fhs:v0.1.0 / /
COPY --from=binary /manager /manager
ENTRYPOINT [ "/manager" ]
