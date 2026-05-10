//! End-to-end SES → S3 round-trip integration test for SesEmailSender.
//!
//! Exercises the production sender path: build SesEmailSender against the
//! real AWS account, send a magic-link to a unique
//! `magic-link-test-{uuid}@<MAIL_DOMAIN>` recipient, and poll the inbound
//! S3 bucket (provisioned per `docs/cloud-setup.md` §2.1) until the MIME
//! object lands. Then assert the body contains the unique token + landing
//! URL, and clean up every test object before exiting.
//!
//! ## Skipping
//!
//! Marked `#[ignore]` so `cargo test` skips it. Run explicitly:
//!
//! ```bash
//! awsp agentkeys-admin
//! RUN_SES_INTEGRATION_TESTS=1 ACCOUNT_ID=429071895007 \
//!   cargo test -p agentkeys-broker-server --features auth-email-link \
//!     --test ses_email_flow -- --ignored
//! ```
//!
//! Without `RUN_SES_INTEGRATION_TESTS=1` the test still gets invoked by
//! `--ignored`, but early-returns with a `println!` skip notice so a CI
//! that runs `--ignored` without AWS creds doesn't false-fail.
//!
//! ## Cleanup invariant
//!
//! Whether the test passes, fails, or panics mid-flow, every S3 object
//! whose key contains the per-test UUID is deleted. Implemented via a
//! `CleanupGuard` Drop impl so a panic doesn't leak a test message into
//! the bucket's 30-day TTL window.

#![cfg(feature = "auth-email-link")]

use std::time::Duration;

use agentkeys_broker_server::plugins::auth::{EmailSender, SesEmailSender};
use aws_sdk_s3::Client as S3Client;

const ENV_GATE: &str = "RUN_SES_INTEGRATION_TESTS";
const DEFAULT_REGION: &str = "us-east-1";
const DEFAULT_MAIL_DOMAIN: &str = "bots.litentry.org";
const DEFAULT_FROM_LOCAL: &str = "noreply-test"; // → noreply-test@<MAIL_DOMAIN>
const POLL_INTERVAL: Duration = Duration::from_secs(5);
const POLL_MAX_ATTEMPTS: usize = 12; // 60s total
const INBOUND_PREFIX: &str = "inbound/";

struct TestEnv {
    region: String,
    account_id: String,
    mail_domain: String,
    bucket: String,
    from_address: String,
}

impl TestEnv {
    fn from_env_or_skip() -> Option<Self> {
        if std::env::var(ENV_GATE).ok().as_deref() != Some("1") {
            println!(
                "ses_email_flow: SKIP — set {}=1 to run the live SES round-trip",
                ENV_GATE
            );
            return None;
        }
        let account_id = match std::env::var("ACCOUNT_ID") {
            Ok(v) if !v.is_empty() => v,
            _ => {
                println!("ses_email_flow: SKIP — ACCOUNT_ID env var required");
                return None;
            }
        };
        let region = std::env::var("AWS_REGION")
            .or_else(|_| std::env::var("REGION"))
            .unwrap_or_else(|_| DEFAULT_REGION.to_string());
        let mail_domain =
            std::env::var("MAIL_DOMAIN").unwrap_or_else(|_| DEFAULT_MAIL_DOMAIN.to_string());
        let bucket = std::env::var("MAIL_BUCKET")
            .unwrap_or_else(|_| format!("agentkeys-mail-{}", account_id));
        // BROKER_EMAIL_FROM_ADDRESS matches the env var the broker reads at
        // runtime (per crates/agentkeys-broker-server/src/env.rs:143). Default
        // to noreply-test@<MAIL_DOMAIN> — must be registered + verified per
        // scripts/ses-verify-sender.sh before this test will pass.
        let from_address = std::env::var("BROKER_EMAIL_FROM_ADDRESS")
            .unwrap_or_else(|_| format!("{}@{}", DEFAULT_FROM_LOCAL, mail_domain));
        Some(Self {
            region,
            account_id,
            mail_domain,
            bucket,
            from_address,
        })
    }
}

/// Drop-time cleanup — guarantees every test object gets deleted even
/// on panic. Holds an S3 client + the test UUID so it can list-and-delete
/// at drop time without re-loading config.
struct CleanupGuard {
    s3: S3Client,
    bucket: String,
    token: String,
}

impl Drop for CleanupGuard {
    fn drop(&mut self) {
        // Drop usually runs WHILE still inside the tokio runtime (the
        // `#[tokio::test]` machinery hasn't shut the runtime down yet),
        // which makes `Handle::block_on` panic with "Cannot start a
        // runtime from within a runtime". The escape is `block_in_place`
        // — it temporarily suspends the current async task so a nested
        // blocking operation is legal. Requires a multi_thread runtime,
        // which the #[tokio::test(flavor = "multi_thread")] attribute on
        // the test guarantees.
        let s3 = self.s3.clone();
        let bucket = self.bucket.clone();
        let token = self.token.clone();
        let cleanup_fut = async move {
            let listed = match s3
                .list_objects_v2()
                .bucket(&bucket)
                .prefix(INBOUND_PREFIX)
                .send()
                .await
            {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("CleanupGuard: list_objects_v2 failed: {e}");
                    return;
                }
            };
            for obj in listed.contents() {
                let Some(key) = obj.key() else { continue };
                // Only delete objects whose body contains our unique
                // token — safer than deleting on key alone (SES doesn't
                // encode recipient in the key).
                let body = match s3.get_object().bucket(&bucket).key(key).send().await {
                    Ok(o) => match o.body.collect().await {
                        Ok(b) => String::from_utf8_lossy(&b.to_vec()).to_string(),
                        Err(_) => continue,
                    },
                    Err(_) => continue,
                };
                if body.contains(&token) {
                    let _ = s3.delete_object().bucket(&bucket).key(key).send().await;
                    println!("CleanupGuard: deleted {key}");
                }
            }
        };
        match tokio::runtime::Handle::try_current() {
            Ok(handle) => {
                // Nested block_on inside the test's runtime — only legal
                // wrapped in block_in_place on a multi_thread runtime.
                tokio::task::block_in_place(|| handle.block_on(cleanup_fut));
            }
            Err(_) => {
                // No runtime active (e.g. test panicked before the
                // runtime shut down cleanly). Spin one up.
                let rt = match tokio::runtime::Runtime::new() {
                    Ok(rt) => rt,
                    Err(e) => {
                        eprintln!("CleanupGuard: failed to spawn runtime: {e}");
                        return;
                    }
                };
                rt.block_on(cleanup_fut);
            }
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "live AWS round-trip — requires RUN_SES_INTEGRATION_TESTS=1 + agentkeys-admin creds"]
async fn ses_send_and_receive_round_trip() {
    let Some(env) = TestEnv::from_env_or_skip() else {
        return;
    };

    let token = uuid::Uuid::new_v4().to_string();
    let recipient = format!("magic-link-test-{}@{}", token, env.mail_domain);
    let from_address = env.from_address.clone();
    let landing_url = format!("https://test.example/landing?token={}", token);

    log("account={} region={}", &[&env.account_id, &env.region]);
    log("bucket={}", &[&env.bucket]);
    log("from={} → to={}", &[&from_address, &recipient]);
    log("token={}", &[&token]);

    let sdk_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region(aws_config::Region::new(env.region.clone()))
        .load()
        .await;

    let sender = SesEmailSender::new(&sdk_config, from_address.clone());
    assert_eq!(sender.from_address(), from_address);

    // Pre-flight: confirm the FROM identity is verified for sending.
    log("verify_sender_ready: calling SES GetEmailIdentity({})", &[&from_address]);
    sender
        .verify_sender_ready()
        .await
        .expect("FROM identity not verified for sending — run scripts/ses-verify-sender.sh");
    log("verify_sender_ready: ok", &[]);

    let s3 = S3Client::new(&sdk_config);
    // Cleanup guard registered BEFORE send so a panic between send + assert
    // still purges the bucket.
    let _guard = CleanupGuard {
        s3: s3.clone(),
        bucket: env.bucket.clone(),
        token: token.clone(),
    };

    log("send_magic_link: calling SES SendEmail…", &[]);
    sender
        .send_magic_link(&recipient, &landing_url)
        .await
        .expect("SES SendEmail failed");
    log("send_magic_link: ok — polling for inbound delivery to S3", &[]);

    // Poll S3 for an inbound object whose body contains our unique token.
    // To keep iteration fast even when the bucket has thousands of stale
    // objects, sort by LastModified desc and examine only the most recent
    // EXAMINE_PER_ATTEMPT objects each iteration.
    const EXAMINE_PER_ATTEMPT: usize = 20;
    let mut found_body: Option<String> = None;
    'poll: for attempt in 1..=POLL_MAX_ATTEMPTS {
        log(
            "attempt {}/{} — list_objects_v2 prefix={}",
            &[&attempt.to_string(), &POLL_MAX_ATTEMPTS.to_string(), INBOUND_PREFIX],
        );
        let listed = match s3
            .list_objects_v2()
            .bucket(&env.bucket)
            .prefix(INBOUND_PREFIX)
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                log("attempt {}: list_objects_v2 ERROR: {}", &[&attempt.to_string(), &format!("{e}")]);
                tokio::time::sleep(POLL_INTERVAL).await;
                continue 'poll;
            }
        };
        let total = listed.contents().len();
        // Newest first.
        let mut objs: Vec<_> = listed.contents().to_vec();
        objs.sort_by(|a, b| b.last_modified().cmp(&a.last_modified()));
        let recent = &objs[..objs.len().min(EXAMINE_PER_ATTEMPT)];
        log(
            "attempt {}: bucket has {} object(s); examining {} most recent",
            &[
                &attempt.to_string(),
                &total.to_string(),
                &recent.len().to_string(),
            ],
        );

        for (i, obj) in recent.iter().enumerate() {
            let Some(key) = obj.key() else { continue };
            let object = match s3.get_object().bucket(&env.bucket).key(key).send().await {
                Ok(o) => o,
                Err(e) => {
                    log("  [{}/{}] {} get_object ERROR: {}",
                        &[&(i+1).to_string(), &recent.len().to_string(), key, &format!("{e}")]);
                    continue;
                }
            };
            let bytes = match object.body.collect().await {
                Ok(b) => b.to_vec(),
                Err(e) => {
                    log("  [{}/{}] {} body.collect ERROR: {}",
                        &[&(i+1).to_string(), &recent.len().to_string(), key, &format!("{e}")]);
                    continue;
                }
            };
            let body_str = String::from_utf8_lossy(&bytes).to_string();
            let hit = body_str.contains(&token);
            log(
                "  [{}/{}] {} size={}B contains_token={}",
                &[
                    &(i + 1).to_string(),
                    &recent.len().to_string(),
                    key,
                    &bytes.len().to_string(),
                    if hit { "YES" } else { "no" },
                ],
            );
            if hit {
                log("attempt {}: FOUND token in {}", &[&attempt.to_string(), key]);
                found_body = Some(body_str);
                break;
            }
        }
        if found_body.is_some() {
            break 'poll;
        }
        log(
            "attempt {}: token not in {} most recent objects, sleeping {}s",
            &[
                &attempt.to_string(),
                &recent.len().to_string(),
                &POLL_INTERVAL.as_secs().to_string(),
            ],
        );
        tokio::time::sleep(POLL_INTERVAL).await;
    }

    let body = found_body.unwrap_or_else(|| {
        panic!(
            "inbound MIME object containing test token {} did not arrive in {}s. \
             Possible causes: SES in sandbox + recipient unverified; SES suppressed \
             the address; SES receipt rule not active for {} (check: \
             aws ses describe-active-receipt-rule-set --region {})",
            token,
            POLL_INTERVAL.as_secs() * POLL_MAX_ATTEMPTS as u64,
            env.mail_domain,
            env.region,
        )
    });
    assert!(
        body.contains(&token),
        "MIME body must contain unique token {token}"
    );
    assert!(
        body.contains(&landing_url) || body.contains(&landing_url.replace('=', "=3D")),
        "MIME body must contain landing URL {landing_url} (allowing for quoted-printable encoding)"
    );

    log("test ok — CleanupGuard will purge inbound objects on Drop", &[]);
    // CleanupGuard runs on Drop after this point.
}

/// Unbuffered logger used throughout this test. Stdout in `cargo test
/// --nocapture` is piped (not a TTY) so println! is fully buffered and
/// hides per-attempt progress until the test completes — eprintln! +
/// explicit flush gives instant feedback.
fn log(template: &str, args: &[&str]) {
    use std::io::Write;
    let mut out = template.to_string();
    for arg in args {
        if let Some(pos) = out.find("{}") {
            out.replace_range(pos..pos + 2, arg);
        }
    }
    eprintln!("ses_email_flow: {}", out);
    let _ = std::io::stderr().flush();
}
