## Blaze

Open Blaze (dev container: aarch64 ....)

This will run the docker linux container.

On terminal, do:

To compile, run ```./build.sh```

To clean, do ```make clean```

To debug, run ```debug.sh ... files... ``` e.g.
```./debug.sh ./main.blz```

In VSC, make sure C/C++ Microsoft Extension is loaded, and start debugging with menu 'Start Debugging', or click on ```Debug blaze``` button.

By default, this should break on _start.
