"""The accounts this machine knows, and whether their tokens are valid."""

from . import errors, fmt


def account_id(ctx):
    """The account's id: <NAME>_CLOUDFLARE_ACCOUNT_ID, else the one account its token sees."""
    if ctx.account.account_id:
        return ctx.account.account_id
    seen = ctx.api.get("/accounts") or []
    if len(seen) != 1:
        raise errors.ConfigError(
            "the token of %s sees %d accounts: set %s_CLOUDFLARE_ACCOUNT_ID"
            % (ctx.account.name, len(seen), ctx.account.name.upper())
        )
    ctx.account.account_id = seen[0]["id"]
    return ctx.account.account_id


def accounts(args, ctx):
    config = ctx.config
    default = config.default_account.lower() if config.default_account else None
    rows = [
        {"name": a.name, "default": a.name == default, "source": a.source, "account_id": a.account_id}
        for a in config.accounts().values()
    ]
    if args.json:
        return fmt.as_json(rows)
    return fmt.table(rows, ["name", "default", "source", "account_id"])


def auth_check(args, ctx):
    try:
        verified = ctx.api.get("/user/tokens/verify")
    except errors.ApiError:
        # An account-owned token is verified on its account, not on the user.
        verified = ctx.api.get("/accounts/%s/tokens/verify" % account_id(ctx))
    row = {"account": ctx.account.name, "status": verified.get("status"),
           "token_id": verified.get("id"), "expires_on": verified.get("expires_on")}
    if args.json:
        return fmt.as_json(row)
    return fmt.table([row], ["account", "status", "token_id", "expires_on"])


def register(subparsers):
    parser = subparsers.add_parser("accounts", help="the accounts found, with no API call")
    parser.set_defaults(handler=accounts, read=True, account_free=True)

    parser = subparsers.add_parser("auth-check", help="verify the account's token")
    parser.set_defaults(handler=auth_check, read=True)
