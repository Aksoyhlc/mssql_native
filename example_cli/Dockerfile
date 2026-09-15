# Build from the repository root:
# docker build --platform linux/amd64 -f example_cli/Dockerfile -t mssql-cli .
FROM dart:3.10 AS runtimelibs
RUN mkdir -p /runtime/tmp && chmod 1777 /runtime/tmp

# The compiler is installed in the builder only; the hook invokes it.
FROM dart:3.10 AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
WORKDIR /app/example_cli
RUN dart pub get
RUN dart build cli --target=bin/main.dart --output=build/release

# There is no Flutter SDK, compiler or separately installed SQL driver here.
FROM scratch
COPY --from=runtimelibs /runtime/ /
COPY --from=runtimelibs /usr/lib/x86_64-linux-gnu/gconv/ /usr/lib/x86_64-linux-gnu/gconv/
COPY --from=build /app/example_cli/build/release/bundle/ /app/
WORKDIR /app
ENTRYPOINT ["/app/bin/main"]
