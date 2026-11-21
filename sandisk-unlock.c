// sandisk-unlock — native Apple Silicon unlock for SanDisk Extreme 55AE
//
// Sends only three vendor SCSI commands through the drive's SES LUN:
//   0xC0        read encryption status
//   0xD8        read HandyStore security block 1 (salt + iteration count)
//   0xC1/0xE1   unlock with the cooked password
//
// There is deliberately no code path for erase, password change, DEK reset,
// firmware update or any data write.
//
// Build: clang -O2 -Wall -Wextra -arch arm64 -o sandisk-unlock sandisk-unlock.c \
//          -framework IOKit -framework CoreFoundation

#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <IOKit/scsi/SCSITask.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <readpassphrase.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CMD_STATUS      0xC0
#define CMD_READ_HS     0xD8
#define CMD_UNLOCK      0xC1
#define UNLOCK_ACTION   0xE1
#define HS_BLOCK_SEC    1
#define MAX_PASSWORD    256

static int has_substr(const unsigned char *hay, size_t hay_len, const char *needle) {
    size_t n = strlen(needle);
    if (n == 0 || n > hay_len) return 0;
    for (size_t i = 0; i + n <= hay_len; i++)
        if (memcmp(hay + i, needle, n) == 0) return 1;
    return 0;
}

static int send_scsi(SCSITaskInterface **task,
                     const uint8_t *cdb, uint8_t cdb_len,
                     void *buf, size_t len, uint8_t direction,
                     uint32_t timeout_ms,
                     SCSI_Sense_Data *sense_out,
                     SCSITaskStatus *status_out,
                     uint64_t *xfer_out) {
    SCSITaskSGElement sge = { (IOVirtualAddress)(uintptr_t)buf, (UInt64)len };
    SCSI_Sense_Data sense;
    SCSITaskStatus status = 0xff;
    UInt64 xfer = 0;

    memset(&sense, 0, sizeof(sense));

    IOReturn r = (*task)->SetCommandDescriptorBlock(task, (UInt8 *)cdb, cdb_len);
    if (r != kIOReturnSuccess) return -1;

    if (len > 0) {
        r = (*task)->SetScatterGatherEntries(task, &sge, 1, (UInt64)len, direction);
        if (r != kIOReturnSuccess) return -1;
    }

    (*task)->SetTimeoutDuration(task, timeout_ms);
    r = (*task)->ExecuteTaskSync(task, &sense, &status, &xfer);

    if (sense_out) *sense_out = sense;
    if (status_out) *status_out = status;
    if (xfer_out) *xfer_out = xfer;

    if (r != kIOReturnSuccess) return -1;
    if (status != kSCSITaskStatus_GOOD) return -1;
    return 0;
}

// Find the SanDisk SES LUN. The data LUN is claimed by the in-kernel driver,
// but the SES LUN stays available without unmounting the volume.
static int find_ses(SCSITaskDeviceInterface ***dev_out, SCSITaskInterface ***task_out) {
    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    if (!match) return -1;

    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) != KERN_SUCCESS)
        return -1;

    io_service_t svc;
    while ((svc = IOIteratorNext(it))) {
        IOCFPlugInInterface **plug = NULL;
        SInt32 score = 0;

        if (IOCreatePlugInInterfaceForService(svc, kIOSCSITaskDeviceUserClientTypeID,
                                              kIOCFPlugInInterfaceID, &plug, &score) == KERN_SUCCESS && plug) {
            SCSITaskDeviceInterface **dev = NULL;
            HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID),
                                                  (LPVOID *)&dev);
            if (hr == 0 && dev) {
                if ((*dev)->ObtainExclusiveAccess(dev) == kIOReturnSuccess) {
                    SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
                    if (task) {
                        uint8_t inq[96];
                        uint8_t cdb[6] = { 0x12, 0, 0, 0, 96, 0 };
                        memset(inq, 0, sizeof(inq));
                        if (send_scsi(task, cdb, sizeof(cdb), inq, sizeof(inq),
                                      kSCSIDataTransfer_FromTargetToInitiator, 30000,
                                      NULL, NULL, NULL) == 0 &&
                            has_substr(inq + 8, 8, "SanDisk") &&
                            has_substr(inq + 16, 16, "SES")) {
                            *dev_out = dev;
                            *task_out = task;
                            IOObjectRelease(svc);
                            IOObjectRelease(it);
                            return 0;
                        }
                        (*task)->Release(task);
                    }
                    (*dev)->ReleaseExclusiveAccess(dev);
                }
                (*dev)->Release(dev);
            }
            (*plug)->Release(plug);
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return -1;
}

static const char *state_name(uint8_t s) {
    switch (s) {
        case 0x00: return "no lock (encryption off)";
        case 0x01: return "LOCKED";
        case 0x02: return "unlocked";
        case 0x06: return "locked, unlock blocked (attempts exceeded)";
        case 0x07: return "no keys";
        default:   return "unknown";
    }
}

static int get_status(SCSITaskInterface **task, uint8_t out[32]) {
    uint8_t cdb[10] = { CMD_STATUS, 0x45, 0, 0, 0, 0, 0, 0, 0x20, 0 };
    memset(out, 0, 32);
    if (send_scsi(task, cdb, sizeof(cdb), out, 32,
                  kSCSIDataTransfer_FromTargetToInitiator, 30000,
                  NULL, NULL, NULL) != 0)
        return -1;
    if (out[0] != 0x45) return -1;
    return 0;
}

static int read_hs1(SCSITaskInterface **task, uint8_t out[512]) {
    // CDB byte 5 = block number low byte (block 1), byte 8 = 1 block of 512.
    uint8_t cdb[10] = { CMD_READ_HS, 0, 0, 0, 0, HS_BLOCK_SEC, 0, 0, 1, 0 };
    memset(out, 0, 512);
    return send_scsi(task, cdb, sizeof(cdb), out, 512,
                     kSCSIDataTransfer_FromTargetToInitiator, 30000,
                     NULL, NULL, NULL);
}

static uint8_t hs_checksum(const uint8_t *b) {
    unsigned sum = 0;
    for (int i = 0; i < 510; i++) sum += b[i];
    sum += b[0];
    return (uint8_t)(-(uint8_t)sum);
}

static int hs_valid(const uint8_t *b) {
    static const uint8_t sig[4] = { 0x00, 0x01, 0x44, 0x57 };
    return memcmp(b, sig, 4) == 0 && hs_checksum(b) == b[511];
}

// cooked = SHA-256^iterations( UTF-16LE( salt_text + password ) )
static int cook_password(const uint8_t salt[8], uint32_t iterations,
                         const char *password, uint8_t out[32]) {
    if (iterations == 0 || iterations > 1000000) return -1;
    if (!password || password[0] == '\0') return -1;

    uint8_t buf[512];
    size_t n = 0;

    // Salt is stored as eight UTF-16LE bytes; stop at the first NUL unit.
    for (int i = 0; i < 8; i += 2) {
        uint16_t u = (uint16_t)(salt[i] | (salt[i + 1] << 8));
        if (u == 0) break;
        buf[n++] = salt[i];
        buf[n++] = salt[i + 1];
    }

    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, password,
                                              kCFStringEncodingUTF8);
    if (!s) return -1;

    CFIndex used = 0;
    Boolean ok = CFStringGetBytes(s, CFRangeMake(0, CFStringGetLength(s)),
                                  kCFStringEncodingUTF16LE, 0, false,
                                  buf + n, (CFIndex)(sizeof(buf) - n), &used);
    CFRelease(s);
    if (!ok || used <= 0) return -1;
    n += (size_t)used;

    CC_SHA256(buf, (CC_LONG)n, out);
    for (uint32_t i = 1; i < iterations; i++)
        CC_SHA256(out, CC_SHA256_DIGEST_LENGTH, out);

    memset(buf, 0, sizeof(buf));
    return 0;
}

static void print_salt(const uint8_t salt[8]) {
    for (int i = 0; i < 8; i += 2) {
        uint16_t u = (uint16_t)(salt[i] | (salt[i + 1] << 8));
        if (u == 0) break;
        if (u >= 32 && u < 127) putchar((int)u);
        else printf("\\u%04x", u);
    }
}

static void print_utf16le(const uint8_t *p, size_t maxbytes) {
    for (size_t i = 0; i + 1 < maxbytes; i += 2) {
        uint16_t u = (uint16_t)(p[i] | (p[i + 1] << 8));
        if (u == 0) break;
        if (u >= 32 && u < 127) putchar((int)u);
        else if (u < 0x80) putchar('?');
        else printf("\\u%04x", u);
    }
}

static int unlock_once(SCSITaskInterface **task, const char *password,
                       uint8_t state_before) {
    uint8_t hs[512];
    if (read_hs1(task, hs) != 0) {
        fprintf(stderr, "error: could not read the drive's security block.\n");
        return -1;
    }
    if (!hs_valid(hs)) {
        fprintf(stderr, "error: security block signature/checksum is invalid; refusing to guess.\n");
        return -1;
    }

    uint32_t iterations = (uint32_t)hs[8] | ((uint32_t)hs[9] << 8) |
                          ((uint32_t)hs[10] << 16) | ((uint32_t)hs[11] << 24);
    const uint8_t *salt = hs + 12;

    printf("Security block: salt=\"");
    print_salt(salt);
    printf("\", iterations=%u, checksum=OK\n", iterations);

    if (iterations == 0 || iterations > 1000000) {
        fprintf(stderr, "error: implausible iteration count; refusing.\n");
        return -1;
    }

    uint8_t cooked[32];
    if (cook_password(salt, iterations, password, cooked) != 0) {
        fprintf(stderr, "error: password could not be encoded; refusing.\n");
        return -1;
    }

    uint8_t param[40];
    memset(param, 0, sizeof(param));
    param[0] = 0x45;          // signature
    param[7] = 0x20;          // cooked password length, big-endian 32
    memcpy(param + 8, cooked, 32);

    uint8_t cdb[10] = { CMD_UNLOCK, UNLOCK_ACTION, 0, 0, 0, 0, 0, 0, 0x28, 0 };

    SCSI_Sense_Data sense;
    SCSITaskStatus status = 0xff;
    memset(&sense, 0, sizeof(sense));

    printf("Sending one unlock command (state was 0x%02x)...\n", state_before);
    int rc = send_scsi(task, cdb, sizeof(cdb), param, sizeof(param),
                       kSCSIDataTransfer_FromInitiatorToTarget, 30000,
                       &sense, &status, NULL);

    memset(cooked, 0, sizeof(cooked));
    memset(param, 0, sizeof(param));

    if (rc != 0) {
        fprintf(stderr, "Unlock command was rejected: SCSI status=0x%02x "
                        "sense=0x%02x/0x%02x/0x%02x\n",
                status, sense.SENSE_KEY, sense.ADDITIONAL_SENSE_CODE,
                sense.ADDITIONAL_SENSE_CODE_QUALIFIER);
        return -1;
    }

    uint8_t st[32];
    if (get_status(task, st) != 0) {
        fprintf(stderr, "Unlock command was accepted, but status could not be re-read.\n");
        return -1;
    }
    printf("State after unlock: 0x%02x (%s)\n", st[3], state_name(st[3]));
    return (st[3] == 0x02 || st[3] == 0x00) ? 0 : -1;
}

static int selftest(void) {
    static const struct { const char *pw; const char *hex; } v[] = {
        { "test", "0ed98ad58a934dcfe18a89291f72bbe7d4f9f34d3c6d0920ec14598f96907359" },
        { "CorrectHorseBatteryStaple", "d7c9ca442fb78b1991be6b2440f60ecaa386b5f943023e7611953c36f65d1409" },
    };
    const uint8_t salt[8] = { 'W', 0, 'D', 0, 'C', 0, '.', 0 };

    for (size_t i = 0; i < sizeof(v) / sizeof(v[0]); i++) {
        uint8_t out[32], want[32];
        if (cook_password(salt, 1000, v[i].pw, out) != 0) {
            printf("FAIL: cook_password error\n");
            return 1;
        }
        for (int j = 0; j < 32; j++) {
            unsigned x;
            sscanf(v[i].hex + 2 * j, "%2x", &x);
            want[j] = (uint8_t)x;
        }
        if (memcmp(out, want, 32) != 0) {
            printf("FAIL: vector %zu\n", i);
            return 1;
        }
    }
    printf("PASS: KDF matches the vendor algorithm for both vectors\n");
    return 0;
}

static void usage(const char *argv0) {
    fprintf(stderr,
        "usage: %s <command>\n"
        "\n"
        "  status    read-only: show lock state, cipher and password length\n"
        "  state     machine-readable hardware state (0x01 locked, 0x02 unlocked)\n"
        "  hint      read-only: show the SanDisk password hint\n"
        "  info      read-only: status plus salt/iterations from security block 1\n"
        "  unlock    prompt for the password and send exactly one unlock command\n"
        "            (use --stdin to read the password from a pipe)\n"
        "  selftest  verify the password KDF against known vectors\n"
        "\n"
        "This tool never erases, changes the password, resets the DEK or writes data.\n",
        argv0);
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(argv[0]); return 2; }

    if (strcmp(argv[1], "selftest") == 0)
        return selftest();

    if (strcmp(argv[1], "status") != 0 &&
        strcmp(argv[1], "state") != 0 &&
        strcmp(argv[1], "hint") != 0 &&
        strcmp(argv[1], "info") != 0 &&
        strcmp(argv[1], "unlock") != 0) {
        usage(argv[0]);
        return 2;
    }

    SCSITaskDeviceInterface **dev = NULL;
    SCSITaskInterface **task = NULL;
    if (find_ses(&dev, &task) != 0) {
        fprintf(stderr, "error: SanDisk SES device not found. Is the drive connected?\n");
        return 1;
    }

    int rc = 1;
    uint8_t st[32];

    if (get_status(task, st) != 0) {
        fprintf(stderr, "error: encryption status command failed.\n");
        goto out;
    }

    if (strcmp(argv[1], "state") == 0) {
        printf("0x%02x\n", st[3]);
        rc = 0;
        goto out;
    }

    if (strcmp(argv[1], "hint") == 0) {
        uint8_t hs[512];
        if (read_hs1(task, hs) != 0 || !hs_valid(hs)) {
            fprintf(stderr, "error: security block unavailable.\n");
            goto out;
        }
        print_utf16le(hs + 24, 202);
        printf("\n");
        rc = 0;
        goto out;
    }

    printf("SanDisk Extreme 55AE\n");
    printf("  state:          0x%02x (%s)\n", st[3], state_name(st[3]));
    printf("  cipher:         0x%02x\n", st[4]);
    printf("  password bytes: %u\n", (unsigned)((st[6] << 8) | st[7]));
    printf("  key reset:      %02x %02x %02x %02x\n", st[8], st[9], st[10], st[11]);

    if (strcmp(argv[1], "status") == 0) {
        rc = 0;
        goto out;
    }

    if (strcmp(argv[1], "info") == 0) {
        uint8_t hs[512];
        if (read_hs1(task, hs) != 0) {
            fprintf(stderr, "error: could not read security block 1.\n");
            goto out;
        }
        printf("  HS1 signature:  %02x %02x %02x %02x (%s)\n",
               hs[0], hs[1], hs[2], hs[3],
               hs_valid(hs) ? "01WD, checksum OK" : "INVALID");
        printf("  salt:           \"");
        print_salt(hs + 12);
        printf("\"\n");
        printf("  iterations:     %u\n",
               (unsigned)(hs[8] | (hs[9] << 8) | (hs[10] << 16) | (hs[11] << 24)));
        rc = 0;
        goto out;
    }

    // unlock
    if (st[3] == 0x00 || st[3] == 0x02) {
        printf("Drive is already accessible; no unlock command sent.\n");
        rc = 0;
        goto out;
    }
    if (st[3] != 0x01) {
        fprintf(stderr, "Refusing: state 0x%02x is not a normal locked state. "
                        "Do not retry; check the drive on another system.\n", st[3]);
        goto out;
    }

    char password[MAX_PASSWORD];
    memset(password, 0, sizeof(password));

    int use_stdin = (argc >= 3 && strcmp(argv[2], "--stdin") == 0);
    if (use_stdin) {
        if (!fgets(password, sizeof(password), stdin)) {
            fprintf(stderr, "error: could not read password from stdin.\n");
            goto out;
        }
        size_t n = strlen(password);
        while (n > 0 && (password[n - 1] == '\n' || password[n - 1] == '\r'))
            password[--n] = '\0';
    } else {
        printf("\nWARNING: the drive allows a limited number of wrong attempts.\n"
               "Check Caps Lock and layout before continuing. No retry is made.\n\n");
        if (!readpassphrase("Password: ", password, sizeof(password), RPP_ECHO_OFF)) {
            fprintf(stderr, "error: could not read password.\n");
            goto out;
        }
    }
    if (password[0] == '\0') {
        fprintf(stderr, "error: empty password; nothing sent.\n");
        memset(password, 0, sizeof(password));
        goto out;
    }

    rc = unlock_once(task, password, st[3]);
    memset(password, 0, sizeof(password));

    if (rc == 0)
        printf("\nUnlocked. macOS should mount the volume within a few seconds.\n"
               "If it does not appear, open Disk Utility or run: diskutil list\n");

out:
    if (task) (*task)->Release(task);
    if (dev) {
        (*dev)->ReleaseExclusiveAccess(dev);
        (*dev)->Release(dev);
    }
    return rc;
}
