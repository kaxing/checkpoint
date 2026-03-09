FROM alpine:edge AS build

RUN apk add --no-cache zig zstd-dev musl-dev bash coreutils

WORKDIR /src
COPY . .

RUN zig build -Doptimize=ReleaseFast
RUN zig build test

FROM build AS integration
RUN bash test-coverage/integration.sh
