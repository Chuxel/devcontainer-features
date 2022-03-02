BINARY_NAME=entrypoint-bootstrapper
 
build:
	mkdir -p dist
	GOARCH="amd64" GOOS="linux" go build -ldflags '-s -w' -o dist/${BINARY_NAME}-amd64 main.go
	GOARCH="arm64" GOOS="linux" go build -ldflags '-s -w' -o dist/${BINARY_NAME}-arm64 main.go

clean:
	go clean
	rm dist/${BINARY_NAME}