#!/usr/bin/env bash
#
# shellcheck disable=SC1090,SC2155

# Do not pipe the output of this command as it might start a background
# process to start the WildFly server.
_execute_jboss_command() {
    local statusMessage="$1"

    if [ -t 0 ]; then
        error_return "JBoss command on stdin expected. Use a heredoc to specify it."
        return 1
    fi

    # We need to use the 'true' command here since 'read' exits with 1
    # when it encounters EOF. The delimiter is unset here so that 'read'
    # obtains the complete input including all lines and sets it to the
    # command variable. The 'true' command is important for scripts
    # using 'set -e' like the buildpack's compile script so that they
    # don't abort execution on the exit code 1 (see also
    # https://stackoverflow.com/a/15422165). The 'set -e' option is
    # responsible for exiting the shell if a command exits with a non-zero
    # exit status.
    local command
    read -r -d '' command || true

    if ! _is_wildfly_running; then
        _start_wildfly_server
        _wait_until_wildfly_running
    fi

    [ -n "${statusMessage}" ] && status "${statusMessage}..."

    debug_jboss_command "${command}"

    "${JBOSS_CLI}" --connect --command="${command}" | indent
    local exitStatus="${PIPESTATUS[0]}"

    if [ "${exitStatus}" -ne 0 ]; then
        error_return "JBoss command failed with exit code ${exitStatus}"
    fi

    return "${exitStatus}"
}

_execute_jboss_command_pipable() {
    if [ -t 0 ]; then
        # Redirect error message to stderr to enable piping stdout
        # to another process
        error_return "JBoss command on stdin expected. Use a heredoc to specify it." >&2
        return 1
    fi

    # We need to use the 'true' command here since 'read' exits with 1
    # when it encounters EOF. The delimiter is unset here so that 'read'
    # obtains the complete input including all lines and sets it to the
    # command variable. The 'true' command is important for scripts
    # using 'set -e' like the buildpack's compile script so that they
    # don't abort execution on the exit code 1 (see also
    # https://stackoverflow.com/a/15422165). The 'set -e' option is
    # responsible for exiting the shell if a command exits with a non-zero
    # exit status.
    local command
    read -r -d '' command || true

    # Redirect debug message to stderr to enable piping stdout to
    # another process
    debug_jboss_command "${command}" >&2

    "${JBOSS_CLI}" --connect --command="${command}"
    local exitStatus="$?"

    if [ "${exitStatus}" -ne 0 ]; then
        # Redirect error message to stderr to enable piping stdout
        # to another process
        error_return "JBoss command failed with exit code ${exitStatus}" >&2
    fi

    return "${exitStatus}"
}

_start_wildfly_server() {
    status "Starting WildFly server..."
    "${JBOSS_HOME}/bin/standalone.sh" --admin-only | indent &
}

_wait_until_wildfly_running() {
    until _is_wildfly_running; do
        sleep 1
    done
    status "WildFly is running"
}

_is_wildfly_running() {
    "${JBOSS_CLI}" --connect --command=":read-attribute(name=server-state)" 2>/dev/null | grep -q "running"
}

_shutdown_wildfly_server() {
    if _is_wildfly_running; then
        status "Shutdown WildFly server"
        "${JBOSS_CLI}" --connect --command=":shutdown" | indent && echo
    fi
}

_shutdown_on_error() {
    debug "Registering ERR trap for shutting down WildFly server on error"
    trap '_shutdown_wildfly_server; exit 1' ERR
}

_load_wildfly_environment_variables() {
    local buildDir="$1"

    if [ -d "${buildDir}/.jboss" ] && [ -z "${JBOSS_HOME}" ]; then
        # Expand the WildFly directory with a glob to get the directory name
        # and version
        local wildflyDir=("${buildDir}"/.jboss/wildfly-*)
        if [ "${#wildflyDir[@]}" -eq 1 ] && [ -d "${wildflyDir[0]}" ]; then
            debug "WildFly installation found at '${wildflyDir[0]}'"

            export JBOSS_HOME="${JBOSS_HOME:-"${wildflyDir[0]}"}" && debug_var "JBOSS_HOME"
            export JBOSS_CLI="${JBOSS_CLI:-"${JBOSS_HOME}/bin/jboss-cli.sh"}" && debug_var "JBOSS_CLI"
            export WILDFLY_VERSION="${WILDFLY_VERSION:-"${JBOSS_HOME#*wildfly-}"}" && debug_var "WILDFLY_VERSION"
        fi
    fi

    if [ -z "${JBOSS_HOME}" ] || \
       [ ! -d "${JBOSS_HOME}" ] || \
       [ ! -f "${JBOSS_HOME}/bin/standalone.sh" ]; then
        error_jboss_home_not_set
        return 1
    fi
}