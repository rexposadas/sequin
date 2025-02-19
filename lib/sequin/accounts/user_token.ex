defmodule Sequin.Accounts.UserToken do
  @moduledoc false
  use Sequin.ConfigSchema

  import Ecto.Query

  alias Sequin.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the reset password token expiry short,
  # since someone with access to the email may take over the account.
  @reset_password_validity_in_days 1
  @confirm_validity_in_days 7
  @change_email_validity_in_days 7
  @session_validity_in_days 60
  @impersonate_validity_in_days 1
  @account_invite_validity_in_days 7
  @team_invite_validity_in_days 7
  @team_invite_current_in_days 1
  schema "users_tokens" do
    # `token` may be a hashed or encrypted token, depending on the context.
    field :token, :binary
    field :hashed_token, :binary
    field :context, :string
    field :sent_to, :string
    field :annotations, :map, default: %{}
    belongs_to :user, Sequin.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def decrypt_team_invite_token(%UserToken{context: "account-team-invite", token: token} = t) do
    decrypted_token = token |> Sequin.Vault.decrypt!() |> Base.url_encode64(padding: false)
    %{t | token: decrypted_token}
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix' default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired. The token system can also be extended
  to store additional data, such as the device used for logging in.
  You could then use this information to display all valid sessions
  and devices in the UI and allow users to explicitly expire any
  session they deem invalid.
  """
  def build_session_token(user, context \\ "session") do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %UserToken{token: token, context: context, user_id: user.id}}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any.

  The token is valid if it matches the value in the database and it has
  not expired (after @session_validity_in_days for "session" context,
  or @impersonate_validity_in_days for "impersonate" context).
  """
  def verify_session_token_query(token, context \\ "session") do
    validity_days =
      case context do
        "session" -> @session_validity_in_days
        "impersonate" -> @impersonate_validity_in_days
      end

    query =
      from token in by_token_and_context_query(token, context),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(^validity_days, "day"),
        select: {user, token.annotations}

    {:ok, query}
  end

  @doc """
  Builds a token and its hash to be delivered to the user's email.

  The non-hashed token is sent to the user email while the
  hashed part is stored in the database. The original token cannot be reconstructed,
  which means anyone with read-only access to the database cannot directly use
  the token in the application to gain access. Furthermore, if the user changes
  their email in the system, the tokens sent to the previous email are no longer
  valid.

  Users can easily adapt the existing code to provide other types of delivery methods,
  for example, by phone numbers.
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any.

  The given token is valid if it matches its hashed counterpart in the
  database and the user email has not changed. This function also checks
  if the token is being used within a certain period, depending on the
  context. The default contexts supported by this function are either
  "confirm", for account confirmation emails, and "reset_password",
  for resetting the password. For verifying requests to change the email,
  see `verify_change_email_token_query/2`.
  """
  def verify_email_token_query(token, context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)
        days = days_for_context(context)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^days, "day") and token.sent_to == user.email,
            select: user

        {:ok, query}

      :error ->
        :error
    end
  end

  defp days_for_context("confirm"), do: @confirm_validity_in_days
  defp days_for_context("reset_password"), do: @reset_password_validity_in_days

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any.

  This is used to validate requests to change the user
  email. It is different from `verify_email_token_query/2` precisely because
  `verify_email_token_query/2` validates the email has not changed, which is
  the starting point by this function.

  The given token is valid if it matches its hashed counterpart in the
  database and if it has not expired (after @change_email_validity_in_days).
  The context must always start with "change:".
  """
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  def verify_team_invite_token_query(token) do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false) do
      hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

      query =
        from token in UserToken,
          where: token.context == "account-team-invite",
          where: token.hashed_token == ^hashed_token,
          where: token.inserted_at > ago(@team_invite_validity_in_days, "day")

      {:ok, query}
    end
  end

  @doc """
  Returns the token struct for the given token value and context.
  """
  def by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end

  @doc """
  Gets all tokens for the given user for the given contexts.
  """
  def by_user_and_contexts_query(user, :all) do
    from t in UserToken, where: t.user_id == ^user.id
  end

  def by_user_and_contexts_query(user, [_ | _] = contexts) do
    from t in UserToken, where: t.user_id == ^user.id and t.context in ^contexts
  end

  def build_impersonation_token(impersonating_user, impersonated_user) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {token,
     %UserToken{
       token: token,
       context: "impersonate",
       user_id: impersonating_user.id,
       annotations: %{impersonated_user_id: impersonated_user.id}
     }}
  end

  def build_account_invite_token(user, account_id, sent_to) do
    {encoded_token, user_token} = build_hashed_token(user, "account-invite", sent_to)
    {encoded_token, %{user_token | annotations: %{account_id: account_id}}}
  end

  def build_team_invite_token(user, account_id) do
    token = :crypto.strong_rand_bytes(@rand_size)
    encrypted_token = Sequin.Vault.encrypt!(token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: encrypted_token,
       hashed_token: :crypto.hash(@hash_algorithm, token),
       context: "account-team-invite",
       user_id: user.id,
       annotations: %{account_id: account_id}
     }}
  end

  def account_invite_token_query(account_id, sent_to) do
    from t in UserToken,
      where: t.context == "account-invite",
      where: fragment("? @> ?", t.annotations, ^%{"account_id" => account_id}),
      where: t.sent_to == ^sent_to
  end

  def pending_invites_query(account_id) do
    from ut in UserToken,
      where: ut.context == "account-invite",
      where: fragment("? @> ?", ut.annotations, ^%{"account_id" => account_id}),
      select: %{sent_to: ut.sent_to, inserted_at: ut.inserted_at, id: ut.id}
  end

  def account_invite_by_user_query(user_id, user_token_id) do
    from ut in UserToken,
      where: ut.context == "account-invite",
      where: ut.user_id == ^user_id,
      where: ut.id == ^user_token_id
  end

  def accept_invite_query(token) do
    from ut in UserToken,
      where: ut.context == "account-invite",
      where: ut.token == ^token,
      where: ut.inserted_at > ago(@account_invite_validity_in_days, "day")
  end

  def current_team_invite_query(account_id) do
    from t in UserToken,
      where: t.context == "account-team-invite",
      where: fragment("? @> ?", t.annotations, ^%{"account_id" => account_id}),
      where: t.inserted_at > ago(@team_invite_current_in_days, "day")
  end
end
