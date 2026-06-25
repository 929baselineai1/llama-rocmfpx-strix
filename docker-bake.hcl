# Multi-arch build definitions for docker buildx bake
# Usage:
#   docker buildx bake -f docker-bake.hcl
#   docker buildx bake -f docker-bake.hcl --push
#
# Tags:
#   baselineai/llama-rocmfpx-strix:fedora-43
#   baselineai/llama-rocmfpx-strix:ubuntu-24.04
#   baselineai/llama-rocmfpx-strix:latest  (= fedora-43)

group "default" {
    targets = ["fedora-43", "ubuntu-24-04"]
}

target "fedora-43" {
    context    = "."
    dockerfile = "Containerfile.fedora"
    tags       = [
        "baselineai/llama-rocmfpx-strix:fedora-43",
        "baselineai/llama-rocmfpx-strix:latest",
    ]
    platforms  = ["linux/amd64"]
    pull       = true
}

target "ubuntu-24-04" {
    context    = "."
    dockerfile = "Containerfile.ubuntu"
    tags       = [
        "baselineai/llama-rocmfpx-strix:ubuntu-24.04",
    ]
    platforms  = ["linux/amd64"]
    pull       = true
}
