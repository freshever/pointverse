FROM --platform=$BUILDPLATFORM golang:1.25.3-alpine AS build
ARG TARGETOS=linux
ARG TARGETARCH
ARG GOPROXY=https://proxy.golang.org,direct
WORKDIR /src
COPY go.mod go.sum ./
RUN GOPROXY=$GOPROXY go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server && \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/migrate ./cmd/migrate

FROM alpine:3.22
RUN apk add --no-cache ca-certificates && addgroup -S app && adduser -S -G app app
RUN mkdir -p /data/cloud && chown app:app /data/cloud
WORKDIR /app
COPY --from=build /out/ /app/
USER app
EXPOSE 8080
ENTRYPOINT ["/app/server"]
