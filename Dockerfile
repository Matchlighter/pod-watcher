# Multi-stage Dockerfile for Crystal Pod Watcher
FROM crystallang/crystal:1.14.0-alpine AS builder

WORKDIR /app

# Copy shard files
COPY shard.yml shard.lock* ./

# Install dependencies
RUN shards install --production

# Copy source code
COPY main.cr .

# Build the application (statically linked)
RUN crystal build --release --static --no-debug main.cr -o pod-watcher

# Final stage - minimal runtime
FROM alpine:latest

WORKDIR /app

# Copy the compiled binary
COPY --from=builder /app/pod-watcher .

# Run as non-root user
RUN adduser -D -u 1000 appuser && \
    chown -R appuser:appuser /app

USER appuser

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

# Run the application
CMD ["./pod-watcher"]
