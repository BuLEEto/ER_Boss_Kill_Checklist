APP_NAME := er-boss-checklist

.PHONY: all build clean run

all: build

build:
	odin build . -out:$(APP_NAME) -extra-linker-flags:"-static"

run: build
	./$(APP_NAME)

clean:
	rm -f $(APP_NAME) $(APP_NAME).exe
