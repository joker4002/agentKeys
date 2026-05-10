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
const POLL_INTERVAL: Duration = Duration::from_secs(5);
const POLL_MAX_ATTEMPTS: usize = 12; // 60s total
const INBOUND_PREFIX: &str = "inbound/";

struct TestEnv {
    region: String,
    account_id: String,
    mail_domain: String,
    bucket: String,
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
        Some(Self {
            region,
            account_id,
            mail_domain,
            bucket,
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
        // Drop runs on the test thread; spin a tokio runtime if we're not
        // already inside one. The integration test is async so we usually
        // are — guard with try_handle for safety.
        let s3 = self.s3.clone();
        let bucket = self.bucket.clone();
        let token = self.token.clone();
        let cleanup = async move {
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
                // Only delete objects whose body we know contains our
                // unique token — safer than deleting on key alone (SES
                // doesn't put recipient in the key).
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
            Ok(h) => {
                h.block_on(cleanup);
            }
            Err(_) => {
                let rt = match tokio::runtime::Runtime::new() {
                    Ok(rt) => rt,
                    Err(e) => {
                        eprintln!("CleanupGuard: failed to spawn runtime: {e}");
                        return;
                    }
                };
                rt.block_on(cleanup);
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
    let from_address = format!("noreply@{}", env.mail_domain);
    let landing_url = format!("https://test.example/landing?token={}", token);

    println!("ses_email_flow: account={} region={}", env.account_id, env.region);
    println!("ses_email_flow: bucket={}", env.bucket);
    println!("ses_email_flow: from={} → to={}", from_address, recipient);

    let sdk_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region(aws_config::Region::new(env.region.clone()))
        .load()
        .await;

    let sender = SesEmailSender::new(&sdk_config, from_address.clone());
    assert_eq!(sender.from_address(), from_address);

    // Pre-flight: confirm the FROM identity is verified for sending.
    sender
        .verify_sender_ready()
        .await
        .expect("FROM identity not verified for sending — cloud-setup.md §2.1 must be done");

    let s3 = S3Client::new(&sdk_config);
    // Cleanup guard registered BEFORE send so a panic between send + assert
    // still purges the bucket.
    let _guard = CleanupGuard {
        s3: s3.clone(),
        bucket: env.bucket.clone(),
        token: token.clone(),
    };

    sender
        .send_magic_link(&recipient, &landing_url)
        .await
        .expect("SES SendEmail failed");

    // Poll S3 for an inbound object whose body contains our unique token.
    let mut found_body: Option<String> = None;
    for attempt in 1..=POLL_MAX_ATTEMPTS {
        let listed = s3
            .list_objects_v2()
            .bucket(&env.bucket)
            .prefix(INBOUND_PREFIX)
            .send()
            .await
            .expect("list_objects_v2 failed");
        for obj in listed.contents() {
            let Some(key) = obj.key() else { continue };
            let object = match s3.get_object().bucket(&env.bucket).key(key).send().await {
                Ok(o) => o,
                Err(_) => continue,
            };
            let bytes = match object.body.collect().await {
                Ok(b) => b.to_vec(),
                Err(_) => continue,
            };
            let body_str = String::from_utf8_lossy(&bytes).to_string();
            if body_str.contains(&token) {
                println!("ses_email_flow: found inbound object key={key} (attempt {attempt})");
                found_body = Some(body_str);
                break;
            }
        }
        if found_body.is_some() {
            break;
        }
        println!(
            "ses_email_flow: attempt {}/{} — token not yet in bucket, sleeping {:?}",
            attempt, POLL_MAX_ATTEMPTS, POLL_INTERVAL
        );
        tokio::time::sleep(POLL_INTERVAL).await;
    }

    let body = found_body.expect("inbound MIME object containing test token did not arrive in 60s");
    assert!(
        body.contains(&token),
        "MIME body must contain unique token {token}"
    );
    assert!(
        body.contains(&landing_url) || body.contains(&landing_url.replace('=', "=3D")),
        "MIME body must contain landing URL {landing_url} (allowing for quoted-printable encoding)"
    );

    // CleanupGuard runs on Drop after this point.
}
