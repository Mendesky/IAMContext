#------- build -------
FROM swift:latest AS builder

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
# Not --static-swift-stdlib: the runtime stage below is swift:slim, which
# already ships the full Swift runtime, so static linking buys nothing here
# and --static-swift-stdlib + Foundation is currently broken on Linux
# (undefined ICU references linking libFoundationInternationalization.a —
# https://github.com/swiftlang/swift-package-manager/issues/10564).
RUN --mount=type=ssh swift build -c release

# set up the dist folder
WORKDIR /dist

# copy the app executable file to dist
RUN cp ${BUILD_FOLDER}/${APP_NAME} ./

# copy every target's resource bundle to dist. Swift 6.4+'s build system (Swift Build)
# emits them as `<Package>_<Target>.bundle`; `Bundle.module` looks for that exact
# name next to the executable and traps at first use if it is missing.
# (e.g. EmployeeAccessAggregate's processed openapi.yaml bundle).
RUN find -L ${BUILD_FOLDER}/ -regex '.*\.bundle$' -exec cp -Ra {} ./ \;

#------- package -------
FROM swift:slim
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
