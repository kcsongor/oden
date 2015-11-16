GIT_REV_LONG=$(shell git rev-parse HEAD)
GIT_REV_SHORT=$(shell git rev-parse --short HEAD)
VERSION ?= $(GIT_REV_SHORT)

SOURCES=$(shell find src -name *.rkt)

OS=$(shell tools/get_os.sh)
DIST_NAME=oden-$(VERSION)-$(OS)
DIST_ZIP=target/$(DIST_NAME).zip

.PHONY: all
all: dist

.PHONY:clean
clean:
	rm -rf target

.PHONY: test
test:
	raco test src/*-test.rkt

target/odenc: $(SOURCES)
	mkdir -p target
	raco exe -o target/odenc src/cmd/odenc.rkt

$(GITBOOK):
	npm install gitbook-cli

target/oden: test target/odenc compile-experiments README.md
	mkdir -p target/oden
	raco distribute target/oden target/odenc
	cp README.md target/oden/README.txt
	echo "$(VERSION) (git revision: $(GIT_REV_LONG))" >> target/oden/VERSION.txt

$(DIST_ZIP): target/oden
	(cd target/oden && zip ../$(DIST_NAME).zip -r *)

.PHONY: compile-experiments
compile-experiments: target/odenc
	ODEN_PATH=experiments/working target/odenc $(PWD)/target/experiments
	GOPATH=$(PWD)/target/experiments go build ...

dist: $(DIST_ZIP)

release: $(DIST_ZIP)
	@echo "\n\nDon't forget to set env variable GITHUB_TOKEN first!\n\n"
	go get github.com/aktau/github-release
	-git tag -d $(VERSION)
	git tag -a -m "Release $(VERSION)" $(VERSION)
	git push origin +$(VERSION)
	-github-release release \
		--user oden-lang \
		--repo oden \
		--tag $(VERSION) \
		--name $(VERSION) \
		--pre-release
	github-release upload \
		--user oden-lang \
		--repo oden \
		--tag $(VERSION) \
		--name "$(DIST_NAME).zip" \
		--file $(DIST_ZIP)








