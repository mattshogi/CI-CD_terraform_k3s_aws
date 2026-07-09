# syntax=docker/dockerfile:1

FROM golang:1.25-alpine AS builder
WORKDIR /src
# Copy module files first so dependency download stays cached across code edits
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/hello .

# Distroless static: no shell, no package manager, runs as non-root (uid 65532)
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/hello /hello
EXPOSE 5678
USER nonroot:nonroot
ENTRYPOINT ["/hello"]
