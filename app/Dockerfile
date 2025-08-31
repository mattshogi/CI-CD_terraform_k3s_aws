FROM golang:1.21-alpine AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o hello .

FROM alpine:3.18
COPY --from=builder /src/hello /usr/local/bin/hello
EXPOSE 5678
ENTRYPOINT ["/usr/local/bin/hello"]
