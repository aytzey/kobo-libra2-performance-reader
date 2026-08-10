#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>


#include "../include/SDL2/SDL.h"


int screenWidth = 0;
int screenHeight = 0;


void printEvent(const SDL_Event * event)
{
    if (event->type == SDL_WINDOWEVENT) {
        switch (event->window.event) {
        case SDL_WINDOWEVENT_SHOWN:
            SDL_Log("Window %d shown", event->window.windowID);
            break;

        case SDL_WINDOWEVENT_HIDDEN:
            SDL_Log("Window %d hidden", event->window.windowID);
            break;

        case SDL_WINDOWEVENT_EXPOSED:
            SDL_Log("Window %d exposed", event->window.windowID);
            break;

        case SDL_WINDOWEVENT_MOVED:
            SDL_Log("Window %d moved to %d,%d",
                    event->window.windowID, event->window.data1,
                    event->window.data2);
            break;

        case SDL_WINDOWEVENT_RESIZED:
            SDL_Log("Window %d resized to %dx%d",
                    event->window.windowID, event->window.data1,
                    event->window.data2);
            break;

        case SDL_WINDOWEVENT_SIZE_CHANGED:
            SDL_Log("Window %d size changed to %dx%d",
                    event->window.windowID, event->window.data1,
                    event->window.data2);
            screenWidth = event->window.data1;
            screenHeight = event->window.data1;
            break;

        case SDL_WINDOWEVENT_MINIMIZED:
            SDL_Log("Window %d minimized", event->window.windowID);
            break;

        case SDL_WINDOWEVENT_MAXIMIZED:
            SDL_Log("Window %d maximized", event->window.windowID);
            break;

        case SDL_WINDOWEVENT_RESTORED:
            SDL_Log("Window %d restored", event->window.windowID);
            break;

        case SDL_WINDOWEVENT_ENTER:
            SDL_Log("Mouse entered window %d",
                    event->window.windowID);
            break;

        case SDL_WINDOWEVENT_LEAVE:
            SDL_Log("Mouse left window %d", event->window.windowID);
            break;

        case SDL_WINDOWEVENT_FOCUS_GAINED:
            SDL_Log("Window %d gained keyboard focus",
                    event->window.windowID);
            break;

        case SDL_WINDOWEVENT_FOCUS_LOST:
            SDL_Log("Window %d lost keyboard focus",
                    event->window.windowID);
            break;

        case SDL_WINDOWEVENT_CLOSE:
            SDL_Log("Window %d closed", event->window.windowID);
            break;

        default:
            SDL_Log("Window %d got unknown event %d",
                    event->window.windowID, event->window.event);
            break;
        }
    }
}


int main(int argc, char* argv[])
{
    SDL_Window *window;
    SDL_Renderer *renderer;
    SDL_Event event;
    int quit = 0;
    int i;


    printf("Starting...\n");
    fflush(stdout);


    sleep(1);


    // Initialize SDL
    printf("SDL_Init()\n");
    fflush(stdout);
    if(SDL_Init(SDL_INIT_VIDEO) != 0)
    {
        printf("Initialization failed: %s\n", SDL_GetError());
        fflush(stdout);

        return EXIT_FAILURE;
    }



    SDL_DisplayMode mode;
    printf("SDL_GetCurrentDisplayMode()\n");
    fflush(stdout);
    if(SDL_GetCurrentDisplayMode(0, &mode) != 0)
    {
        printf("Could not get current mode: %s\n", SDL_GetError());
        fflush(stdout);

        return EXIT_FAILURE;
    }

    screenWidth = mode.w;
    screenHeight = mode.h;

    printf("SDL_CreateWindowAndRenderer(%i, %i)\n",
           screenWidth,
           screenHeight);
    fflush(stdout);
    SDL_CreateWindowAndRenderer(screenWidth, screenHeight, SDL_WINDOW_RESIZABLE, &window, &renderer);

    if (window == NULL) {
        printf("Window creation failed: %s\n", SDL_GetError());
        fflush(stdout);

        return EXIT_FAILURE;
    }


    printf("Initialized, drawing...\n");
    fflush(stdout);


    // Initialize random number generator
    srand(42);

    // Loop!
    while(!quit)
    {
        // Handle all queued events
        while (SDL_PollEvent(&event)) {
            // Handle event
            switch (event.type)
            {
            // SDL wants to quit!
            case SDL_QUIT:
                quit = 1;
                break;
            }
        }

        // Draw random pixels
        for(i = 0; i < 20000; i++)
        {
            SDL_SetRenderDrawColor(renderer, rand() % 256, rand() % 256, rand() % 256, 255);
            //SDL_RenderDrawPoint(renderer, rand() % screenWidth, rand() % screenHeight);
            SDL_RenderDrawLine(renderer, rand() % screenWidth, rand() % screenHeight, rand() % screenWidth, rand() % screenHeight);
        }

        // Flip surface
        SDL_RenderPresent(renderer);


        // Handle events
        SDL_PumpEvents();

        if(SDL_PeepEvents(&event, 1, SDL_GETEVENT, SDL_FIRSTEVENT, SDL_LASTEVENT))
            printEvent(&event);
    }

    // Destroy the window
    SDL_DestroyWindow(window);

    // Quit SDL
    SDL_Quit();

    return EXIT_SUCCESS;
}
