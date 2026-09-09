from PIL import Image, ImageDraw

S = 64
img = Image.new("RGBA", (S, S), (30, 30, 46, 255))
d = ImageDraw.Draw(img)
# green prompt glyph ">_"
d.line([(14, 20), (26, 32), (14, 44)], fill=(166, 227, 161, 255), width=6, joint="curve")
d.line([(30, 44), (50, 44)], fill=(166, 227, 161, 255), width=6)
img.save(r"C:\Users\me\Desktop\flax-mcp-main\tools\prompt-popper\icon.ico", sizes=[(16, 16), (32, 32), (48, 48), (64, 64)])
print("icon written")
