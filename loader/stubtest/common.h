/* bare-metal helpers for qemu -M versatilepb (PL011 at 0x101f1000) */
typedef unsigned int u32;
static inline void putc_(char c) { *(volatile u32 *)0x101f1000 = c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void hex_(u32 v) { int i; for (i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]); }
static u32 crc32_(const unsigned char *p, u32 n)
{ u32 c = 0xffffffff, i; int k; for (i = 0; i < n; i++) { c ^= p[i]; for (k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320 & -(c & 1)); } return ~c; }
