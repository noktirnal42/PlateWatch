# Reproducible REST mirror image. CloudKit remains the Apple backend; this
# image is the reference boundary for Android/web/edge clients.
FROM swift:6.2-jammy AS build
WORKDIR /build

COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product App

FROM ubuntu:22.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libatomic1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/.build/release/App /app/App

ENV HOST=0.0.0.0
ENV PORT=8083
EXPOSE 8083
USER nobody
ENTRYPOINT ["/app/App"]
CMD ["serve"]
