//! 連線配對與裝置權杖(GLOSSARY)的保存處：`devices.json`,只存配對碼與權杖的 SHA-256。
//!
//! 主機服務與管理指令(另一個行程)共用這個檔案，每次讀寫都先鎖 `devices.lock`。

use std::fs::{File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

/// 配對碼的有效時間。
pub const PAIRING_CODE_LIFETIME: Duration = Duration::from_secs(5 * 60);

/// 連續猜錯這麼多次後，所有尚未使用的配對碼作廢。
pub const MAX_FAILED_PAIRING_ATTEMPTS: u32 = 5;

/// 配對碼字元：去掉容易看錯的 0、1、I、O。
const PAIRING_CODE_ALPHABET: &[u8; 32] = b"23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
const PAIRING_CODE_LENGTH: usize = 8;
const DEVICE_TOKEN_PREFIX: &str = "purrdr_dt_";

/// 已配對的裝置(不含權杖)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub device_id: String,
    pub name: String,
    pub read_only: bool,
    pub paired_at: SystemTime,
    pub last_connected_at: Option<SystemTime>,
    pub revoked_at: Option<SystemTime>,
}

/// 配對指令產生的配對碼;明文只在這裡出現一次。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingCode {
    /// 顯示用格式 `XXXX-XXXX`。
    pub code: String,
    pub read_only: bool,
    pub expires_at: SystemTime,
}

/// 配對成功發出的裝置權杖;明文只在這裡出現一次。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IssuedDevice {
    pub device: Device,
    pub device_token: String,
}

/// 配對失敗的原因。
#[derive(Debug)]
pub enum PairingFailure {
    /// 不存在、已用過，或連續猜錯後已作廢。
    Invalid,
    Expired,
    Storage(io::Error),
}

/// 權杖不被接受的原因。
#[derive(Debug)]
pub enum TokenRejection {
    /// 沒帶、格式不對或不認得。
    Invalid,
    Revoked(Device),
    Storage(io::Error),
}

/// 撤銷失敗的原因。
#[derive(Debug)]
pub enum RevokeFailure {
    UnknownDevice,
    Storage(io::Error),
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct StoredState {
    #[serde(default)]
    devices: Vec<StoredDevice>,
    #[serde(default)]
    pairing_codes: Vec<StoredPairingCode>,
    #[serde(default)]
    failed_pairing_attempts: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredDevice {
    device_id: String,
    name: String,
    token_sha256: String,
    read_only: bool,
    paired_at: u64,
    #[serde(default)]
    last_connected_at: Option<u64>,
    #[serde(default)]
    revoked_at: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredPairingCode {
    code_sha256: String,
    read_only: bool,
    expires_at: u64,
}

impl StoredDevice {
    fn device(&self) -> Device {
        Device {
            device_id: self.device_id.clone(),
            name: self.name.clone(),
            read_only: self.read_only,
            paired_at: from_unix_seconds(self.paired_at),
            last_connected_at: self.last_connected_at.map(from_unix_seconds),
            revoked_at: self.revoked_at.map(from_unix_seconds),
        }
    }
}

/// 主機服務資料夾裡的裝置與配對碼。
#[derive(Debug, Clone)]
pub struct DeviceStore {
    directory: PathBuf,
}

impl DeviceStore {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        DeviceStore { directory: directory.into() }
    }

    /// 產生一次性配對碼，`now` 起 [`PAIRING_CODE_LIFETIME`] 內有效。
    pub fn create_pairing_code(&self, read_only: bool, now: SystemTime) -> io::Result<PairingCode> {
        let mut random = [0u8; PAIRING_CODE_LENGTH];
        fill_random(&mut random)?;
        let characters: String = random.iter().map(|byte| PAIRING_CODE_ALPHABET[usize::from(byte % 32)] as char).collect();
        let expires_at = now + PAIRING_CODE_LIFETIME;
        self.update(|state| {
            let now_seconds = unix_seconds(now);
            state.pairing_codes.retain(|pending| pending.expires_at > now_seconds);
            state.pairing_codes.push(StoredPairingCode {
                code_sha256: sha256_hex(&characters),
                read_only,
                expires_at: unix_seconds(expires_at),
            });
        })?;
        Ok(PairingCode {
            code: format!("{}-{}", &characters[..4], &characters[4..]),
            read_only,
            expires_at,
        })
    }

    /// 以配對碼換裝置權杖。配對碼用過即作廢。
    pub fn redeem_pairing_code(&self, code: &str, device_name: &str, now: SystemTime) -> Result<IssuedDevice, PairingFailure> {
        let normalized: String = code
            .chars()
            .filter(|character| !matches!(character, '-' | ' '))
            .map(|character| character.to_ascii_uppercase())
            .collect();
        let candidate = sha256_hex(&normalized);
        let mut device_token_bytes = [0u8; 32];
        let mut device_id_bytes = [0u8; 8];
        fill_random(&mut device_token_bytes).map_err(PairingFailure::Storage)?;
        fill_random(&mut device_id_bytes).map_err(PairingFailure::Storage)?;
        let device_token = format!("{DEVICE_TOKEN_PREFIX}{}", hex(&device_token_bytes));
        let device_id = hex(&device_id_bytes);
        let now_seconds = unix_seconds(now);

        self.update(|state| {
            let matched = state
                .pairing_codes
                .iter()
                .position(|pending| constant_time_equal(&pending.code_sha256, &candidate));
            let Some(index) = matched else {
                state.failed_pairing_attempts += 1;
                if state.failed_pairing_attempts >= MAX_FAILED_PAIRING_ATTEMPTS {
                    state.pairing_codes.clear();
                    state.failed_pairing_attempts = 0;
                }
                return Err(PairingFailure::Invalid);
            };
            let pending = state.pairing_codes.remove(index);
            if pending.expires_at <= now_seconds {
                return Err(PairingFailure::Expired);
            }
            state.failed_pairing_attempts = 0;
            let stored = StoredDevice {
                device_id,
                name: device_name.to_owned(),
                token_sha256: sha256_hex(&device_token),
                read_only: pending.read_only,
                paired_at: now_seconds,
                last_connected_at: None,
                revoked_at: None,
            };
            let device = stored.device();
            state.devices.push(stored);
            Ok(IssuedDevice { device, device_token })
        })
        .map_err(PairingFailure::Storage)?
    }

    /// 找出權杖所屬的裝置。
    pub fn authenticate(&self, device_token: &str) -> Result<Device, TokenRejection> {
        let candidate = sha256_hex(device_token);
        let state = self.read().map_err(TokenRejection::Storage)?;
        let mut matched = None;
        for stored in &state.devices {
            if constant_time_equal(&stored.token_sha256, &candidate) {
                matched = Some(stored);
            }
        }
        match matched {
            None => Err(TokenRejection::Invalid),
            Some(stored) if stored.revoked_at.is_some() => Err(TokenRejection::Revoked(stored.device())),
            Some(stored) => Ok(stored.device()),
        }
    }

    /// 記下裝置的最後連線時間。
    pub fn record_connection(&self, device_id: &str, now: SystemTime) -> io::Result<()> {
        self.update(|state| {
            if let Some(stored) = state.devices.iter_mut().find(|stored| stored.device_id == device_id) {
                stored.last_connected_at = Some(unix_seconds(now));
            }
        })
    }

    /// 撤銷裝置;已撤銷的裝置保留紀錄，以便回報「已撤銷」而不是「不認得」。
    pub fn revoke(&self, device_id: &str, now: SystemTime) -> Result<Device, RevokeFailure> {
        self.update(|state| {
            let stored = state
                .devices
                .iter_mut()
                .find(|stored| stored.device_id == device_id)
                .ok_or(RevokeFailure::UnknownDevice)?;
            stored.revoked_at.get_or_insert(unix_seconds(now));
            Ok(stored.device())
        })
        .map_err(RevokeFailure::Storage)?
    }

    /// 所有裝置(含已撤銷),依配對先後。
    pub fn devices(&self) -> io::Result<Vec<Device>> {
        Ok(self.read()?.devices.iter().map(StoredDevice::device).collect())
    }

    fn state_path(&self) -> PathBuf {
        self.directory.join("devices.json")
    }

    fn lock(&self, exclusive: bool) -> io::Result<File> {
        create_private_directory(&self.directory)?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.directory.join("devices.lock"))?;
        if exclusive {
            lock.lock()?
        } else {
            lock.lock_shared()?
        }
        Ok(lock)
    }

    fn read(&self) -> io::Result<StoredState> {
        let _lock = self.lock(false)?;
        self.load()
    }

    fn update<T>(&self, change: impl FnOnce(&mut StoredState) -> T) -> io::Result<T> {
        let _lock = self.lock(true)?;
        let mut state = self.load()?;
        let outcome = change(&mut state);
        let temporary = self.directory.join("devices.json.tmp");
        write_private_file(&temporary, &serde_json::to_vec_pretty(&state).expect("狀態可序列化"))?;
        std::fs::rename(&temporary, self.state_path())?;
        Ok(outcome)
    }

    fn load(&self) -> io::Result<StoredState> {
        match std::fs::read(self.state_path()) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(StoredState::default()),
            Err(error) => Err(error),
        }
    }
}

fn fill_random(buffer: &mut [u8]) -> io::Result<()> {
    getrandom::fill(buffer).map_err(|error| io::Error::other(error.to_string()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn sha256_hex(text: &str) -> String {
    hex(&Sha256::digest(text.as_bytes()))
}

/// 雜湊比對不因比對到第幾個位元組而有時間差。
fn constant_time_equal(left: &str, right: &str) -> bool {
    left.as_bytes().ct_eq(right.as_bytes()).into()
}

fn unix_seconds(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH).map(|elapsed| elapsed.as_secs()).unwrap_or(0)
}

fn from_unix_seconds(seconds: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(seconds)
}

#[cfg(unix)]
fn create_private_directory(directory: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(directory)
}

#[cfg(not(unix))]
fn create_private_directory(directory: &Path) -> io::Result<()> {
    std::fs::create_dir_all(directory)
}

#[cfg(unix)]
fn write_private_file(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(not(unix))]
fn write_private_file(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    let mut file = OpenOptions::new().create(true).truncate(true).write(true).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}
