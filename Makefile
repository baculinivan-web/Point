.PHONY: build test app run release clean

build:
	swift build

test:
	swift test
	swift build --product point-browser-mcp
	python3 scripts/test-mcp-helper.py "$$(swift build --show-bin-path)/point-browser-mcp"

app:
	./scripts/build-app.sh

run: app
	open dist/Point.app

release:
	./scripts/package-release.sh

clean:
	swift package clean
