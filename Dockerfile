FROM archlinux 
WORKDIR /omarchy
RUN pacman -Syu --noconfirm archiso git grub
COPY . .

