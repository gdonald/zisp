pub const retry_limit = 5;
pub const Header = extern struct {
    tag: u8,
    length: u32,
    checksum: u16,
};
