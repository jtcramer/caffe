#include <algorithm>
#include <cfloat>
#include <vector>

#include "caffe/layer.hpp"
#include "caffe/util/math_functions.hpp"
#include "caffe/vision_layers.hpp"

#include <cstdio>
#include <assert.h>

namespace caffe {

template <typename Dtype>
__global__ void BasicMaxPoolForward(const int nthreads, const Dtype* bottom_data,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int kernel_h, const int kernel_w, const int stride_h,
    const int stride_w, const int pad_h, const int pad_w, Dtype* top_data,
    int* mask, Dtype* top_mask) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;
    int hstart = ph * stride_h - pad_h;
    int wstart = pw * stride_w - pad_w;
    int hend = min(hstart + kernel_h, height);
    int wend = min(wstart + kernel_w, width);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    Dtype maxval = -FLT_MAX;
    int maxidx = -1;
    bottom_data += (n * channels + c) * height * width;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        if (bottom_data[h * width + w] > maxval) {
          maxidx = h * width + w;
          maxval = bottom_data[maxidx];
        }
      }
    }
    top_data[index] = maxval;
    if (mask) {
      mask[index] = maxidx;
    } else {
      top_mask[index] = maxidx;
    }
  }
}

template <typename Dtype>
__global__ void MaxPoolForward(const int nthreads, const Dtype* bottom_data,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int kernel_h, const int kernel_w, const int stride_h,
    const int stride_w, const int pad_h, const int pad_w,
    const int pool_block_dim_h, const int pool_block_dim_w,
    const int pool_block_h, const int pool_block_w,
    Dtype* top_data, int* mask, Dtype* top_mask) {

    CUDA_KERNEL_LOOP(index, nthreads) {
        // Calculate the block index for this thread
        int pbw = index % (pool_block_dim_w);
        int pbh = (index / pool_block_dim_w) % pool_block_dim_h;
        // Calculate the batch index and channel index
        int c = (index / pool_block_dim_w / pool_block_dim_h) % channels;
        int n = index / pool_block_dim_w / pool_block_dim_h / channels;

        //int hstart_total = max(pbh*pool_block_h * stride_h - pad_h, 0);
        //int hend_total = min( min((pbh+1)*pool_block_h, pooled_height )*stride_h - pad_h + kernel_h, height);

        //int wstart_total = max(pbw*pool_block_w * stride_w - pad_w, 0);
        //int proc_width = min( min((pbw+1)*pool_block_w, pooled_width )*stride_w - pad_w + kernel_h, width) - wstart_total;

        // This makes the assumption that stride is 1.

        Dtype* input_data = (Dtype*)bottom_data + (n * channels + c) * height * width;

        int register_start_w = max(pbw*pool_block_w - pad_w, 0);
        int register_start_h = max(pbh*pool_block_h - pad_h, 0);
        int register_end_w = min(min((pbw+1)*pool_block_w, pooled_width) - pad_w + kernel_w, width);
        int register_end_h = min(min((pbh+1)*pool_block_h, pooled_height) - pad_h + kernel_h, height);
        int register_width = register_end_w - register_start_w;
        int register_height = register_end_h - register_start_h;

        Dtype registers[12][12];
         
        for (int j = 0; j < register_height; j++) {
          for (int i = 0; i < register_width; i++) {
            registers[j][i] = input_data[register_start_w + i + (register_start_h + j)*width];
          }
        }

        // Make sure we make a new pointer every time, so we don't keep incrementing the same
        // one!

        /*
        Dtype *local_bottom_data = (Dtype*) malloc(proc_width*(hend_total - hstart_total)*sizeof(Dtype));

        for (int h = hstart_total; h <= hend_total; h++)
        {
            memcpy(local_bottom_data + ((h - hstart_total) * proc_width), input_data + (h * width + wstart_total), proc_width * sizeof(Dtype));
        }
        */

        int idx_start = (n*channels + c) * pooled_height;

        // Loop over the pooling "block"
        for (int pw = pbw*pool_block_w - register_start_w; pw < min((pbw+1)*pool_block_w, pooled_width) - register_start_w; pw++) {
            for (int ph = pbh*pool_block_h - register_start_h; ph < min((pbh+1)*pool_block_h, pooled_height) - register_start_h; ph++) {

                // Calculate the bounds within which we calculate the max
                int hstart = ph * stride_h - pad_h;
                int wstart = pw * stride_w - pad_w;
                int hend = min(hstart + kernel_h, register_height);
                int wend = min(wstart + kernel_w, register_width);
                hstart = max(hstart, 0);
                wstart = max(wstart, 0);
                Dtype maxval = -FLT_MAX;
                int maxidx = -1;

                // Find the max in the kernel
                for (int h = hstart; h < hend; ++h) {
                  for (int w = wstart; w < wend; ++w) {
                    if (registers[h][w] > maxval) {
                      maxval = registers[h][w];
                      maxidx = (h + register_start_h) * width + w + register_start_w;
                    }
                  }
                }

                // Calculate the linear array index for the output
                int idx = (idx_start + register_start_h + ph) * pooled_width + pw + register_start_w;
                // Store the max value
                top_data[idx] = maxval;

                // Store the index that the max came from, for backprop
                if (mask) {
                  mask[idx] = maxidx;
                } else {
                  top_mask[idx] = maxidx;
                }
            }
        }

        //free(local_bottom_data); dbd6e9
    }
}

template <typename Dtype>
__global__ void AvePoolForward(const int nthreads, const Dtype* bottom_data,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int kernel_h, const int kernel_w, const int stride_h,
    const int stride_w, const int pad_h, const int pad_w, Dtype* top_data) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;
    int hstart = ph * stride_h - pad_h;
    int wstart = pw * stride_w - pad_w;
    int hend = min(hstart + kernel_h, height + pad_h);
    int wend = min(wstart + kernel_w, width + pad_w);
    int pool_size = (hend - hstart) * (wend - wstart);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    hend = min(hend, height);
    wend = min(wend, width);
    Dtype aveval = 0;
    bottom_data += (n * channels + c) * height * width;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        aveval += bottom_data[h * width + w];
      }
    }
    top_data[index] = aveval / pool_size;
  }
}

template <typename Dtype>
__global__ void StoPoolForwardTrain(const int nthreads,
    const Dtype* bottom_data,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int kernel_h, const int kernel_w, const int stride_h,
    const int stride_w, Dtype* rand_idx, Dtype* top_data) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;
    int hstart = ph * stride_h;
    int hend = min(hstart + kernel_h, height);
    int wstart = pw * stride_w;
    int wend = min(wstart + kernel_w, width);
    Dtype cumsum = 0.;
    bottom_data += (n * channels + c) * height * width;
    // First pass: get sum
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        cumsum += bottom_data[h * width + w];
      }
    }
    float thres = rand_idx[index] * cumsum;
    // Second pass: get value, and set index.
    cumsum = 0;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        cumsum += bottom_data[h * width + w];
        if (cumsum >= thres) {
          rand_idx[index] = ((n * channels + c) * height + h) * width + w;
          top_data[index] = bottom_data[h * width + w];
          return;
        }
      }
    }
  }
}


template <typename Dtype>
__global__ void StoPoolForwardTest(const int nthreads,
    const Dtype* bottom_data,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int kernel_h, const int kernel_w, const int stride_h,
    const int stride_w, Dtype* top_data) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;
    int hstart = ph * stride_h;
    int hend = min(hstart + kernel_h, height);
    int wstart = pw * stride_w;
    int wend = min(wstart + kernel_w, width);
    // We set cumsum to be 0 to avoid divide-by-zero problems
    Dtype cumsum = FLT_MIN;
    Dtype cumvalues = 0.;
    bottom_data += (n * channels + c) * height * width;
    // First pass: get sum
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        cumsum += bottom_data[h * width + w];
        cumvalues += bottom_data[h * width + w] * bottom_data[h * width + w];
      }
    }
    top_data[index] = cumvalues / cumsum;
  }
}


template <typename Dtype>
void PoolingLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom,
      vector<Blob<Dtype>*>* top) {
  const Dtype* bottom_data = bottom[0]->gpu_data();
  Dtype* top_data = (*top)[0]->mutable_gpu_data();
  int count = (*top)[0]->count();
  int new_count;
  //int nthreads;
  // We'll output the mask to top[1] if it's of size >1.
  const bool use_top_mask = top->size() > 1;
  int* mask = NULL;
  Dtype* top_mask = NULL;

  int pooling_block_height = 1;
  int pooling_block_width = 1;
  int pooling_block_dim_height = (pooled_height_ + pooling_block_height - 1) / pooling_block_height;
  int pooling_block_dim_width = (pooled_width_ + pooling_block_width - 1) / pooling_block_width;

  int num_pool_blocks = pooling_block_dim_height * pooling_block_dim_width;
  int num_groups = num_pool_blocks * bottom[0]->num() * channels_;

  switch (this->layer_param_.pooling_param().pool()) {
  case PoolingParameter_PoolMethod_MAX:
    if (use_top_mask) {
      top_mask = (*top)[1]->mutable_gpu_data();
    } else {
      mask = max_idx_.mutable_gpu_data();
    }
    // NOLINT_NEXT_LINE(whitespace/operators)
    if ((stride_h_ == 1) && (stride_w_ == 1) && (kernel_w_ + pooling_block_width - 1 < 13) && (kernel_h_ + pooling_block_height - 1 < 13)) {
      MaxPoolForward<Dtype><<<CAFFE_GET_BLOCKS(num_groups), CAFFE_CUDA_NUM_THREADS>>>(
          num_groups, bottom_data, bottom[0]->num(), channels_,
          height_, width_, pooled_height_, pooled_width_, kernel_h_,
          kernel_w_, stride_h_, stride_w_, pad_h_, pad_w_, 
          pooling_block_dim_height, pooling_block_dim_width,
          pooling_block_height, pooling_block_width,
          top_data, mask, top_mask);
    } else {
      BasicMaxPoolForward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
          count, bottom_data, bottom[0]->num(), channels_,
          height_, width_, pooled_height_, pooled_width_, kernel_h_,
          kernel_w_, stride_h_, stride_w_, pad_h_, pad_w_, top_data,
          mask, top_mask);
    }
    break;
  case PoolingParameter_PoolMethod_AVE:
    // NOLINT_NEXT_LINE(whitespace/operators)
    AvePoolForward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
        count, bottom_data, bottom[0]->num(), channels_,
        height_, width_, pooled_height_, pooled_width_, kernel_h_,
        kernel_w_, stride_h_, stride_w_, pad_h_, pad_w_, top_data);
    break;
  case PoolingParameter_PoolMethod_STOCHASTIC:
    if (Caffe::phase() == Caffe::TRAIN) {
      // We need to create the random index as well.
      caffe_gpu_rng_uniform(count, Dtype(0), Dtype(1),
                            rand_idx_.mutable_gpu_data());
      // NOLINT_NEXT_LINE(whitespace/operators)
      StoPoolForwardTrain<Dtype><<<CAFFE_GET_BLOCKS(count),
                                   CAFFE_CUDA_NUM_THREADS>>>(
          count, bottom_data, bottom[0]->num(), channels_,
          height_, width_, pooled_height_, pooled_width_, kernel_h_,
          kernel_w_, stride_h_, stride_w_,
          rand_idx_.mutable_gpu_data(), top_data);
    } else {
      // NOLINT_NEXT_LINE(whitespace/operators)
      StoPoolForwardTest<Dtype><<<CAFFE_GET_BLOCKS(count),
                                  CAFFE_CUDA_NUM_THREADS>>>(
          count, bottom_data, bottom[0]->num(), channels_,
          height_, width_, pooled_height_, pooled_width_, kernel_h_,
          kernel_w_, stride_h_, stride_w_, top_data);
    }
    break;
  default:
    LOG(FATAL) << "Unknown pooling method.";
  }
  CUDA_POST_KERNEL_CHECK;
}


template <typename Dtype>
__global__ void MaxPoolBackward(const int nthreads, const Dtype* top_diff,
    const int* mask, const Dtype* top_mask, const int num, const int channels,
    const int height, const int width, const int pooled_height,
    const int pooled_width, const int kernel_h, const int kernel_w,
    const int stride_h, const int stride_w, const int pad_h, const int pad_w,
    Dtype* bottom_diff) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    int w = index % width;
    int h = (index / width) % height;
    int c = (index / width / height) % channels;
    int n = index / width / height / channels;
    int phstart =
        (h + pad_h < kernel_h) ? 0 : (h + pad_h - kernel_h) / stride_h + 1;
    int phend = min((h + pad_h) / stride_h + 1, pooled_height);
    int pwstart =
        (w + pad_w < kernel_w) ? 0 : (w + pad_w - kernel_w) / stride_w + 1;
    int pwend = min((w + pad_w) / stride_w + 1, pooled_width);
    Dtype gradient = 0;
    int offset = (n * channels + c) * pooled_height * pooled_width;
    top_diff += offset;
    if (mask) {
      mask += offset;
      for (int ph = phstart; ph < phend; ++ph) {
        for (int pw = pwstart; pw < pwend; ++pw) {
          if (mask[ph * pooled_width + pw] == h * width + w) {
            gradient += top_diff[ph * pooled_width + pw];
          }
        }
      }
    } else {
      top_mask += offset;
      for (int ph = phstart; ph < phend; ++ph) {
        for (int pw = pwstart; pw < pwend; ++pw) {
          if (top_mask[ph * pooled_width + pw] == h * width + w) {
            gradient += top_diff[ph * pooled_width + pw];
          }
        }
      }
    }
    bottom_diff[index] = gradient;
  }
}

template <typename Dtype>
__global__ void AvePoolBackward(const int nthreads, const Dtype* top_diff,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int kernel_h, const int kernel_w, const int stride_h,
    const int stride_w, const int pad_h, const int pad_w,
    Dtype* bottom_diff) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    int w = index % width + pad_w;
    int h = (index / width) % height + pad_h;
    int c = (index / width / height) % channels;
    int n = index / width / height / channels;
    int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    int phend = min(h / stride_h + 1, pooled_height);
    int pwstart = (w < kernel_w) ? 0 : (w - kernel_w) / stride_w + 1;
    int pwend = min(w / stride_w + 1, pooled_width);
    Dtype gradient = 0;
    top_diff += (n * channels + c) * pooled_height * pooled_width;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        // figure out the pooling size
        int hstart = ph * stride_h - pad_h;
        int wstart = pw * stride_w - pad_w;
        int hend = min(hstart + kernel_h, height + pad_h);
        int wend = min(wstart + kernel_w, width + pad_w);
        int pool_size = (hend - hstart) * (wend - wstart);
        gradient += top_diff[ph * pooled_width + pw] / pool_size;
      }
    }
    bottom_diff[index] = gradient;
  }
}


template <typename Dtype>
__global__ void StoPoolBackward(const int nthreads,
    const Dtype* rand_idx, const Dtype* top_diff,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int kernel_h, const int kernel_w, const int stride_h,
    const int stride_w, Dtype* bottom_diff) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    int w = index % width;
    int h = (index / width) % height;
    int c = (index / width / height) % channels;
    int n = index / width / height / channels;
    int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    int phend = min(h / stride_h + 1, pooled_height);
    int pwstart = (w < kernel_w) ? 0 : (w - kernel_w) / stride_w + 1;
    int pwend = min(w / stride_w + 1, pooled_width);
    Dtype gradient = 0;
    rand_idx += (n * channels + c) * pooled_height * pooled_width;
    top_diff += (n * channels + c) * pooled_height * pooled_width;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        gradient += top_diff[ph * pooled_width + pw] *
            (index == static_cast<int>(rand_idx[ph * pooled_width + pw]));
      }
    }
    bottom_diff[index] = gradient;
  }
}


template <typename Dtype>
void PoolingLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
      const vector<bool>& propagate_down, vector<Blob<Dtype>*>* bottom) {
  if (!propagate_down[0]) {
    return;
  }
  const Dtype* top_diff = top[0]->gpu_diff();
  Dtype* bottom_diff = (*bottom)[0]->mutable_gpu_diff();
  const int count = (*bottom)[0]->count();
  caffe_gpu_set(count, Dtype(0.), bottom_diff);
  // We'll output the mask to top[1] if it's of size >1.
  const bool use_top_mask = top.size() > 1;
  const int* mask = NULL;
  const Dtype* top_mask = NULL;
  switch (this->layer_param_.pooling_param().pool()) {
  case PoolingParameter_PoolMethod_MAX:
    if (use_top_mask) {
      top_mask = top[1]->gpu_data();
    } else {
      mask = max_idx_.gpu_data();
    }
    // NOLINT_NEXT_LINE(whitespace/operators)
    MaxPoolBackward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
        count, top_diff, mask, top_mask, top[0]->num(), channels_,
        height_, width_, pooled_height_, pooled_width_,
        kernel_h_, kernel_w_, stride_h_, stride_w_, pad_h_, pad_w_,
        bottom_diff);
    break;
  case PoolingParameter_PoolMethod_AVE:
    // NOLINT_NEXT_LINE(whitespace/operators)
    AvePoolBackward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
        count, top_diff, top[0]->num(), channels_,
        height_, width_, pooled_height_, pooled_width_, kernel_h_,
        kernel_w_, stride_h_, stride_w_, pad_h_, pad_w_, bottom_diff);
    break;
  case PoolingParameter_PoolMethod_STOCHASTIC:
    // NOLINT_NEXT_LINE(whitespace/operators)
    StoPoolBackward<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
        count, rand_idx_.gpu_data(), top_diff,
        top[0]->num(), channels_, height_, width_, pooled_height_,
        pooled_width_, kernel_h_, kernel_w_, stride_h_, stride_w_,
        bottom_diff);
    break;
  default:
    LOG(FATAL) << "Unknown pooling method.";
  }
  CUDA_POST_KERNEL_CHECK;
}


INSTANTIATE_CLASS(PoolingLayer);


}  // namespace caffe
