#------- build -------
# Toolchain 釘死 6.2.4（＝ CI main.yml 測的 6.2 系列）。不要用 swift:latest：
# 它已滾到 6.4.0，該版有 --static-swift-stdlib 遇 Foundation 就掛的上游回歸
#（連結 libFoundation.a 時 undefined reference to CFCharacterSetGetPredefined 等，
#  swiftlang/swift-package-manager#10564）。釘版同時讓 image 可重現。
FROM swift:6.2.4 AS builder

# set up the workspace
WORKDIR /workspace

ENV APP_NAME="IAMContextServer"
ENV BUILD_FOLDER="/workspace/.build/release"

RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
# copy the workspace to the docker image
COPY . /workspace

# IAMContext's deps are all public https packages (no private git@github.com: SSH deps like Middleware),
# so the SSH mount is a no-op here — kept for pipeline uniformity with the other contexts
# (build all with `docker build --ssh default -t ...`).
RUN --mount=type=ssh swift build -c release --static-swift-stdlib

# set up the dist folder
WORKDIR /dist

# copy the app executable file to dist
RUN cp ${BUILD_FOLDER}/${APP_NAME} ./

# copy the resources in all targets what has the postfix with ".resources" to dist
# (e.g. EmployeeAccessAggregate's processed openapi.yaml bundle).
RUN find -L ${BUILD_FOLDER}/ -regex '.*\.resources$' -exec cp -Ra {} ./ \;

#------- package -------
# runtime 與 builder 同版：swift:slim 會跟著 latest 漂，執行期 runtime 與編譯期 toolchain 不同版沒有保證。
FROM swift:6.2.4-slim
ENV APP_NAME="IAMContextServer"

# set up the app folder
WORKDIR /app

# copy all resources and executables file at /dist folder in builder container
COPY --from=builder /dist ./

WORKDIR /usr/bin
RUN ln -s /app/${APP_NAME} server

# HTTP API 24202 (frontend / admin) + gRPC 24203 (PermissionsService, cross-context).
# 服務以 network_mode: host 部署，EXPOSE 僅作文件用途。
EXPOSE 24202 24203

# set the entry point (application name)
CMD ["/usr/bin/server"]
