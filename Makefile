.PHONY: build clean install

build:
	go build -o cc-guard .

clean:
	rm -f cc-guard

install: build
	cp cc-guard /usr/local/bin/cc-guard
