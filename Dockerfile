FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o /http_server .

FROM alpine:3.20
WORKDIR /app
COPY --from=build /http_server /app/http_server
COPY www /app/www
EXPOSE 8080
ENTRYPOINT ["/app/http_server"]
CMD ["8080"]