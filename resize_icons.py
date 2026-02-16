from PIL import Image, ImageDraw, ImageOps, ImageChops
import os

def make_rounded(img, radius_ratio=0.2):
    mask = Image.new('L', img.size, 0)
    draw = ImageDraw.Draw(mask)
    width, height = img.size
    # Draw rounded rectangle
    draw.rounded_rectangle([(0, 0), (width, height)], radius=width*radius_ratio, fill=255)
    
    # Apply mask
    output = ImageOps.fit(img, mask.size, centering=(0.5, 0.5))
    output.putalpha(mask)
    return output

def resize_icon_app(input_path, output_path, size):
    try:
        with Image.open(input_path) as img:
            img = img.convert("RGBA")
            # Zoom crop (15% border removal)
            width, height = img.size
            crop_margin = 0.15
            left = width * crop_margin
            top = height * crop_margin
            right = width * (1 - crop_margin)
            bottom = height * (1 - crop_margin)
            img = img.crop((left, top, right, bottom))
            
            # Resize
            img = img.resize(size, Image.Resampling.LANCZOS)
            
            # Rounded Corners
            img = make_rounded(img, radius_ratio=0.22) # Slightly more rounded for "squircle"
            
            img.save(output_path, "PNG")
            print(f"App Icon: {output_path}")
    except Exception as e:
        print(f"Error app icon: {e}")
        # Fallback if V2 missing
        img = Image.new('RGBA', size, (0, 0, 0, 0))
        img.save(output_path)

def draw_moon_icon(output_path, size, color):
    # Draw a clean vector-like moon using PIL
    w, h = size
    
    # 1. Create Moon mask (White circle)
    moon = Image.new('L', size, 0)
    d_moon = ImageDraw.Draw(moon)
    d_moon.ellipse([2, 2, w-2, h-2], fill=255)
    
    # 2. Create Shadow mask (White circle, offset)
    shadow = Image.new('L', size, 0)
    d_shadow = ImageDraw.Draw(shadow)
    
    shift = w * 0.25
    d_shadow.ellipse([2 + shift, 2 - (shift*0.5), w-2 + shift, h-2 - (shift*0.5)], fill=255)
    
    # 3. Crescent = Moon - Shadow (where moon is white and shadow is black)
    # Start with Moon, subtract Shadow. 
    # Logic: Result = Moon - Shadow. 
    # If Moon=255, Shadow=255 -> 0. 
    # If Moon=255, Shadow=0 -> 255.
    crescent_mask = ImageChops.subtract(moon, shadow)
    
    # 4. Create final colored image
    # Extract RGB from input color tuple
    rgb = color[:3] if len(color) == 4 else color
    
    final = Image.new('RGBA', size, rgb + (0,)) # Base color with 0 alpha
    
    # Apply crescent mask as alpha
    final.putalpha(crescent_mask)
    
    final.save(output_path, "PNG")
    print(f"Generated Moon Icon: {output_path}")

if __name__ == "__main__":
    # 1. App Icon: Restore V2 with rounding
    resize_icon_app("night_mode_icon_v2_1771158188571.png", "app_icon.png", (512, 512))
    
    # 2. Menu Icons: Draw fresh
    # Template (Mono): Black or White? 
    # macOS treating png as template uses alpha channel. 
    # So we draw 'black' (0,0,0) with alpha. macOS converts this to proper menu text color.
    draw_moon_icon("menu_icon.png", (22, 22), color=(0, 0, 0, 255)) # 44px is for @2x, but PIL logic uses px. Let's make 44x44 and resize? Or just draw small.
    # Rumps/macOS standard size is usually 18x18 or 22x22 points. 
    # Let's generate higher res for Retina.
    draw_moon_icon("menu_icon.png", (44, 44), color=(0, 0, 0, 255))
    
    # Active (Color): Yellow/Gold
    draw_moon_icon("menu_icon_on.png", (44, 44), color=(255, 215, 0, 255)) # Gold

