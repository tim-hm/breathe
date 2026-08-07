-- Gender joins the onboarding answers so the coach can calibrate how it reads
-- a breath-test score — the published BOLT reference ranges differ by sex, and
-- a coach that compares everyone against one curve reads half its users wrong.
--
-- A closed list, and deliberately so (product decision, 2026-08-07): the one
-- consumer is a prompt, and a free-text self-describe variant would be a second
-- injection surface bought for a single prose reader. NULL is "rather not say"
-- — absence, not a fourth value — which is why the enum has no UNSPECIFIED
-- member and the column has no default.

CREATE TYPE gender AS ENUM ('FEMALE', 'MALE', 'NON_BINARY');

ALTER TABLE users ADD COLUMN gender gender;
