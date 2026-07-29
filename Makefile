.PHONY: build test app clean

build:
	swift build -c release

test:
	./test.sh

app:
	./install-app.sh

clean:
	rm -rf .build
