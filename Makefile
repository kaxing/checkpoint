.PHONY: build install uninstall test test-multiarch bench release clean

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

release:
	rm -rf release && mkdir release
	zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos
	tar -czf release/check-macos-arm64.tar.gz -C zig-out/bin check
	zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos
	tar -czf release/check-macos-x86_64.tar.gz -C zig-out/bin check
	zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux
	tar -czf release/check-linux-arm64.tar.gz -C zig-out/bin check
	zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux
	tar -czf release/check-linux-x86_64.tar.gz -C zig-out/bin check

clean:
	rm -rf zig-out .zig-cache bench-runner bench-runner.o release
