FROM golang:1.24-alpine AS builder

# Install required packages
RUN apk add --no-cache git ca-certificates

# Set working directory
WORKDIR /build

# Copy go mod files
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build the binary
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o vuln-list-update .

# Final stage
FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache \
    git \
    ca-certificates \
    bash \
    curl \
    tzdata \
    && rm -rf /var/cache/apk/*

# Create app directory
WORKDIR /app

# Copy binary from builder
COPY --from=builder /build/vuln-list-update /app/

# Copy update script
COPY local_run/update-all.sh /app/

# Make scripts executable
RUN chmod +x /app/update-all.sh /app/vuln-list-update

# Create workspace directory
RUN mkdir -p /workspace

# Set environment variables
ENV WORK_DIR=/workspace \
    PATH=/app:$PATH

# Health check
HEALTHCHECK --interval=5m --timeout=30s --start-period=5m \
    CMD test -f /workspace/.last_update && \
        test $(find /workspace/.last_update -mmin -360 | wc -l) -gt 0 || exit 1

# Run the update script
CMD ["/app/update-all.sh"]
