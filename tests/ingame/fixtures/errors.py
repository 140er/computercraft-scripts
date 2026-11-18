"""Errors raised by the Gate B fixture library."""


class FixtureError(RuntimeError):
    def __init__(self, message, command=None, reply=None):
        super().__init__(message)
        self.command = command
        self.reply = reply


# Replies that mean the server rejected the command.
FAIL_SNIPPETS = (
    "Could not set the block",
    "Unable to set block",
    "Unable to set the block",
    "Unknown or incomplete command",
    "Incorrect argument for command",
    "Expected whitespace",
    "Unknown item",
    "No item was found",
    "Could not modify",
    "Could not replace",
    "Invalid item id",
    "Expected value",
)


def ensure_ok(reply, command):
    for snippet in FAIL_SNIPPETS:
        if snippet in reply:
            raise FixtureError(reply.strip(), command, reply)
    return reply
