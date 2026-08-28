#include <fcntl.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        return 2;
    }
    int descriptor = open(argv[1], O_RDWR);
    if (descriptor < 0) {
        return 3;
    }
    struct stat info;
    if (fstat(descriptor, &info) != 0 || info.st_size < (off_t)sizeof(struct mach_header_64)) {
        close(descriptor);
        return 4;
    }
    uint8_t *bytes = mmap(NULL, (size_t)info.st_size, PROT_READ | PROT_WRITE,
                          MAP_SHARED, descriptor, 0);
    if (bytes == MAP_FAILED) {
        close(descriptor);
        return 5;
    }
    struct mach_header_64 *header = (struct mach_header_64 *)bytes;
    if (header->magic != MH_MAGIC_64 ||
        (uint64_t)sizeof(*header) + header->sizeofcmds > (uint64_t)info.st_size) {
        munmap(bytes, (size_t)info.st_size);
        close(descriptor);
        return 6;
    }
    uint8_t *cursor = bytes + sizeof(*header);
    int found = 0;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        struct load_command *command = (struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) ||
            cursor + command->cmdsize > bytes + info.st_size) {
            munmap(bytes, (size_t)info.st_size);
            close(descriptor);
            return 7;
        }
        if (command->cmd == LC_UUID && command->cmdsize == sizeof(struct uuid_command)) {
            struct uuid_command *uuid = (struct uuid_command *)command;
            memset(uuid->uuid, 0, sizeof(uuid->uuid));
            found = 1;
        }
        cursor += command->cmdsize;
    }
    int status = 0;
    if (!found || msync(bytes, (size_t)info.st_size, MS_SYNC) != 0) {
        status = 8;
    }
    if (munmap(bytes, (size_t)info.st_size) != 0 || close(descriptor) != 0) {
        status = 9;
    }
    return status;
}
