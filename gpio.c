#include <stdlib.h>
#include <sys/types.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#define DEV_PATH "/dev/mem"

struct gpio_regs {
	unsigned int gpio_dr;	/* data */
	unsigned int gpio_dir;	/* direction */
	unsigned int gpio_psr;	/* pad satus */
};

int main (int argc, char *argv[])
{
	int num;
	int val;
  int tmp;
	int port;
	int offset;
	int fd;
	struct gpio_regs *regs;
	int gpio_ports[5]={0x30200000,0x30210000,0x30220000,0x30230000,0x30240000};

	if(argc < 2)
	{
		printf("Usage:%s num [val]\n",argv[0]);
		return -1;
	}
	else
	{
		num = atoi(argv[1]);
		if(argc == 3)
		  val = atoi(argv[2]);
	}
	
	if(num > 160)
	{
		printf("invalid gpio num:%d,exit\n",num);
		return -1;
	}

	port = num / 32;
	offset = num & 0x1f;       

  fd = open(DEV_PATH, O_RDWR);
  if (fd <= 0) {
    fprintf(stderr, "open error: %s\n", DEV_PATH);
    return -1;
  }

  regs = (struct gpio_regs *)mmap(NULL, 0x1000, PROT_WRITE, MAP_SHARED, fd, gpio_ports[port]);
  if (regs < 0) {
    fprintf(stderr, "mmap error\n");
    return -1;
  }
  
  if(argc == 2) {
    printf("gpio %d=%d\n",num,((regs->gpio_dr)>>offset) & 0x01);
  } else if(argc >= 3) {
    regs->gpio_dir |= 1 << offset;
    tmp = regs->gpio_dr;
    if(val)
      tmp |= 1 << offset;
    else
      tmp &= ~(1 << offset);
    regs->gpio_dr = tmp;
  }
  
  munmap((void *)regs , 0x1000);
  close(fd);

	return 0;
}
