import sys
import matplotlib.pyplot as plt
import matplotlib.image as mpimg
from matplotlib.patches import Circle
from matplotlib.lines import Line2D

def collect_points_with_zoom(image_path, output_path="points.py", zoom=4, radius=20):
    img = mpimg.imread(image_path)
    points = []

    fig, ax = plt.subplots()
    ax.imshow(img)
    ax.set_autoscale_on(False)
    ax.set_title("Click to select points. Close window when done.")

    # Circle around cursor on main image
    circ = Circle((0, 0), radius, color='red', fill=False, lw=1)
    ax.add_patch(circ)

    # Fixed zoom inset in top-left
    zoom_ax = fig.add_axes([0.05, 0.75, 0.2, 0.2])
    zoom_ax.axis('off')
    zoom_im = zoom_ax.imshow(img, interpolation='nearest')

    # Crosshair lines in zoom as Line2D objects
    hline = Line2D([0, 0], [0, 0], color='red', lw=1)
    vline = Line2D([0, 0], [0, 0], color='red', lw=1)
    zoom_ax.add_line(hline)
    zoom_ax.add_line(vline)

    def onclick(event):
        if event.inaxes != ax:
            return
        if event.xdata is not None and event.ydata is not None:
            x, y = int(event.xdata), int(event.ydata)
            points.append((x, y))
            print(f"Point: ({x}, {y})")
            ax.plot(x, y, 'ro')
            fig.canvas.draw_idle()

    def onmotion(event):
        if event.inaxes != ax:
            return
        if event.xdata is None or event.ydata is None:
            return
        x, y = int(event.xdata), int(event.ydata)

        # Update circle on main image
        circ.center = (x, y)
    
        # Define patch boundaries
        pad = radius * 2
        y0, y1 = max(0, y - pad), min(img.shape[0], y + pad)
        x0, x1 = max(0, x - pad), min(img.shape[1], x + pad)
        patch = img[y0:y1, x0:x1]

        # Set extent to match image coordinates
        zoom_im.set_data(patch)
        zoom_im.set_extent([x0, x1, y1, y0])  # notice y1,y0 to flip vertically
        zoom_ax.set_xlim(x0, x1)
        zoom_ax.set_ylim(y1, y0)

        # Crosshair at exact cursor location
        hline.set_data([x0, x1], [y, y])
        vline.set_data([x, x], [y0, y1])

        fig.canvas.draw_idle()


    fig.canvas.mpl_connect('button_press_event', onclick)
    fig.canvas.mpl_connect('motion_notify_event', onmotion)

    plt.show()

    # Save points as Python list
    with open(output_path, 'w') as f:
        f.write(f"points = {points}\n")
    print(f"Saved {len(points)} points to {output_path}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: python {sys.argv[0]} <image_path>")
        sys.exit(1)
    collect_points_with_zoom(sys.argv[1])

