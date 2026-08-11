.PHONY: build test app run release clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

run: app
	open dist/Point.app

release:
	./scripts/package-release.sh

clean:
	swift package clean
