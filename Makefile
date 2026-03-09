.PHONY: build install uninstall test test-multiarch bench clean

build:
	zig build -Doptimize=ReleaseFast

install: build
	cp zig-out/bin/check /usr/local/bin/check

uninstall:
	rm -f /usr/local/bin/check

test: build
	zig build test
	bash test-coverage/integration.sh

test-multiarch:
	docker buildx build --platform linux/arm64 -f test-coverage/Dockerfile --target integration .
	docker buildx build --platform linux/amd64 -f test-coverage/Dockerfile --target integration .

bench: build
	zig build-exe bench/main.zig --name bench-runner -OReleaseFast && ./bench-runner && rm -f bench-runner bench-runner.o
	bash bench/vs_git.sh

clean:
	rm -rf zig-out .zig-cache bench-runner bench-runner.o
